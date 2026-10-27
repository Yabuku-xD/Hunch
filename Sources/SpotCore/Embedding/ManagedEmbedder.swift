import Foundation

/// Lazily loaded, self-unloading embedder (owner: engine).
///
/// Nothing is loaded at init. The first `embedQueries`/`embedDocuments` call loads the model (concurrent callers share
/// one load); after `idleTimeout` (default 5 min) with no call in flight, no call since and `keepAlive()` false (no
/// pending embeddings), the model is released, and the next call reloads it transparently. A load failure that makes
/// the model unusable (`EmbedderError.isUnavailable`) is remembered and rethrown at once until `retry()`.
public actor ManagedEmbedder: Embedder {
    public typealias Loader = @Sendable (URL, Int) async throws -> any Embedder

    public nonisolated let modelURL: URL
    public nonisolated let dimension: Int
    public nonisolated let idleTimeout: Duration

    private let loader: Loader
    private let keepAlive: @Sendable () async -> Bool
    private var model: (any Embedder)?
    private var loading: Task<any Embedder, any Error>?
    private var active = 0
    private var lastUse = ContinuousClock.now
    private var reaper: Task<Void, Never>?
    private var failure: EmbedderError?
    private var observers: [@Sendable (Bool) -> Void] = []

    /// Completed loads so far.
    public private(set) var loadCount = 0
    /// Wall time of the last successful load.
    public private(set) var lastLoadDuration: Duration?

    public init(modelURL: URL,
                dimension: Int = 256,
                idleTimeout: Duration = .seconds(300),
                keepAlive: @escaping @Sendable () async -> Bool = { false },
                loader: Loader? = nil) {
        self.modelURL = modelURL
        self.dimension = dimension
        self.idleTimeout = idleTimeout
        self.keepAlive = keepAlive
        self.loader = loader ?? { url, dim in try await LlamaEmbedder.load(modelURL: url, dimension: dim) }
    }

    public var isLoaded: Bool { model != nil }
    /// The remembered fatal load error, if any.
    public var loadError: EmbedderError? { failure }

    /// Called with `true` after each load and `false` after each unload.
    public func observe(_ body: @escaping @Sendable (Bool) -> Void) { observers.append(body) }

    // MARK: Embedder

    public func embedQueries(_ q: [String]) async throws -> [[Float]] {
        let m = try await acquire()
        defer { release() }
        return try await m.embedQueries(q)
    }

    public func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] {
        let m = try await acquire()
        defer { release() }
        return try await m.embedDocuments(d)
    }

    // MARK: Lifecycle

    /// Loads now (no-op when loaded). The idle timer starts afterwards.
    public func preload() async throws {
        _ = try await acquire()
        release()
    }

    /// Releases the model now if nothing is in flight. Returns whether it was released.
    @discardableResult
    public func unload() -> Bool {
        guard active == 0, model != nil else { return false }
        model = nil
        reaper?.cancel()
        reaper = nil
        for o in observers { o(false) }
        return true
    }

    /// Forgets a remembered load failure (e.g. after the model file was installed).
    public func retry() { failure = nil }

    private func acquire() async throws -> any Embedder {
        if let failure { throw failure }
        active += 1
        lastUse = .now
        if let model { return model }
        let task: Task<any Embedder, any Error>
        if let loading {
            task = loading
        } else {
            let (loader, url, dim) = (self.loader, modelURL, dimension)
            task = Task.detached(priority: .userInitiated) { try await loader(url, dim) }
            loading = task
        }
        let t0 = ContinuousClock.now
        do {
            let m = try await task.value
            if model == nil, loading == task {
                model = m
                loadCount += 1
                lastLoadDuration = .now - t0
                for o in observers { o(true) }
            }
            if loading == task { loading = nil }
            scheduleReaper()
            return model ?? m
        } catch {
            if loading == task { loading = nil }
            active -= 1
            if let e = error as? EmbedderError, e.isUnavailable { failure = e }
            throw error
        }
    }

    private func release() {
        active = max(0, active - 1)
        lastUse = .now
        scheduleReaper()
    }

    private func scheduleReaper() {
        guard reaper == nil, model != nil else { return }
        reaper = Task { [weak self] in await self?.reap() }
    }

    private func reap() async {
        while !Task.isCancelled {
            let due = lastUse + idleTimeout
            if ContinuousClock.now < due {
                do { try await Task.sleep(until: due, clock: .continuous) } catch { return }
                continue
            }
            guard model != nil else { break }
            if active > 0 {
                lastUse = .now
                continue
            }
            if await keepAlive() {
                lastUse = .now
                continue
            }
            // keepAlive suspended: re-check that nothing started meanwhile.
            if active == 0, ContinuousClock.now >= lastUse + idleTimeout {
                model = nil
                for o in observers { o(false) }
                break
            }
        }
        reaper = nil
    }
}
