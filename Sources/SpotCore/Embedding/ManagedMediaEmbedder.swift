import Foundation

/// Anything that turns an RGB image into a vector in the text query space.
public protocol ImageEmbedding: Sendable {
    func embedImage(_ image: RGBImage) async throws -> [Float]
}

extension MediaEmbedder: ImageEmbedding {}

/// K12(d): the mmproj is mapped only while tier-2/3 work needs it — loaded on the first image, released after
/// `idleTimeout` without one. Text-only queues never load it (`loadCount == 0`).
public actor ManagedMediaEmbedder: ImageEmbedding {
    private let factory: @Sendable () async throws -> any ImageEmbedding
    private let idleTimeout: Duration
    private var loaded: (any ImageEmbedding)?
    private var failed = false
    private var lastUse = ContinuousClock.now
    private var reaper: Task<Void, Never>?
    public private(set) var loadCount = 0

    public init(idleTimeout: Duration = .seconds(120),
                factory: @escaping @Sendable () async throws -> any ImageEmbedding) {
        self.idleTimeout = idleTimeout
        self.factory = factory
    }

    /// The model + `projectorURL` (nil = the projector `ModelStore` resolves).
    public static func standard(modelURL: URL, projectorURL: URL? = nil, dimension: Int = 256) -> ManagedMediaEmbedder {
        ManagedMediaEmbedder {
            try await MediaEmbedder.load(modelURL: modelURL, projectorURL: projectorURL, dimension: dimension)
        }
    }

    public var isLoaded: Bool { loaded != nil }

    public func embedImage(_ image: RGBImage) async throws -> [Float] {
        lastUse = .now
        if loaded == nil {
            guard !failed else { throw MediaEmbedderError.closed }
            do {
                loaded = try await factory()
                loadCount += 1
            } catch {
                failed = true
                throw error
            }
            scheduleReap()
        }
        guard let e = loaded else { throw MediaEmbedderError.closed }
        return try await e.embedImage(image)
    }

    /// Releases the model now.
    public func unload() async {
        if let m = loaded as? MediaEmbedder { await m.close() }
        loaded = nil
        reaper?.cancel()
        reaper = nil
    }

    private func scheduleReap() {
        reaper?.cancel()
        reaper = Task(priority: .background) { [weak self, idleTimeout] in
            while !Task.isCancelled {
                try? await Task.sleep(for: idleTimeout)
                guard let self else { return }
                if await self.reapIfIdle() { return }
            }
        }
    }

    private func reapIfIdle() async -> Bool {
        guard ContinuousClock.now - lastUse >= idleTimeout else { return false }
        if let m = loaded as? MediaEmbedder { await m.close() }
        loaded = nil
        reaper = nil
        return true
    }
}
