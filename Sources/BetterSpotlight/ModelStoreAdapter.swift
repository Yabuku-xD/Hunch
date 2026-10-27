import Foundation
import Synchronization
import SpotCore

// COMPILE-TIME ADAPTER (v4-spec §0 Order 2). SpotCore's `ModelStore.swift` (oss O1) has not landed yet, so this file
// declares the §2 API verbatim in the app module and maps it onto today's `Paths.resolveModel`. Every other app file
// codes against these names only. When O1/O4 land, delete this file: the same names then resolve to SpotCore's types
// (app-module declarations shadow imported ones, so both states compile).

enum ModelFile: String, CaseIterable, Sendable, Codable {
    case text, projector
    var fileName: String {
        switch self {
        case .text: "embeddinggemma-2-Q8_0.gguf"
        case .projector: "mmproj-embeddinggemma-2-Q8_0.gguf"
        }
    }
    var byteCount: Int64 { self == .text ? 309_855_456 : 554_821_024 }
}

enum ModelSource: String, Sendable, Codable, Equatable {
    case override, downloaded, huggingFaceCache, digUp
}

struct ResolvedModel: Sendable, Equatable {
    let text: URL
    let textSource: ModelSource
    let projector: URL?
    let projectorSource: ModelSource?
    var hasProjector: Bool { projector != nil }
}

struct DownloadProgress: Sendable, Equatable {
    let file: ModelFile
    let receivedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double?
    var fraction: Double { totalBytes == 0 ? 0 : Double(receivedBytes) / Double(totalBytes) }
    var secondsRemaining: Double? { bytesPerSecond.map { Double(totalBytes - receivedBytes) / max($0, 1) } }
}

enum ModelStoreError: Error, Sendable, Equatable {
    case offline
    case http(status: Int)
    case checksum(ModelFile)
    case diskFull(needed: Int64, available: Int64)
    case io(String)
}

enum ModelState: Sendable, Equatable {
    case missing
    case downloading(DownloadProgress)
    case paused(DownloadProgress)
    case verifying(ModelFile)
    case ready(ResolvedModel)
    case failed(ModelStoreError, progress: DownloadProgress?)
}

protocol ModelProviding: AnyObject, Sendable {
    var state: ModelState { get }
    func states() -> AsyncStream<ModelState>
    func download()
    func pause()
    func cancel()
    func remove() async throws
    func importFiles(_ urls: [URL]) async throws -> ResolvedModel
    var modelsDirectory: URL { get }
}

/// Stand-in for SpotCore's `ModelStore`: resolution only (no downloads), through the existing `Paths` lookup.
final class ModelStore: ModelProviding {
    static let shared = ModelStore()
    static let downloadBytes: Int64 = 864_676_480

    private let current: Mutex<ModelState>

    init() {
        current = Mutex(Self.resolveNow().map(ModelState.ready) ?? .missing)
    }

    func resolve() -> ResolvedModel? { Self.resolveNow() }

    private static func resolveNow() -> ResolvedModel? {
        guard let text = Paths.resolveModel() else { return nil }
        let source: ModelSource = text.path.contains("/DigUp/") ? .digUp
            : text.path.contains("huggingface") ? .huggingFaceCache : .downloaded
        let projector = Paths.resolveProjector(for: text)
        return ResolvedModel(text: text, textSource: source, projector: projector,
                             projectorSource: projector == nil ? nil : source)
    }

    var state: ModelState { current.withLock { $0 } }
    func states() -> AsyncStream<ModelState> {
        let snapshot = state
        return AsyncStream { $0.yield(snapshot); $0.finish() }
    }
    func download() {}
    func pause() {}
    func cancel() {}
    func remove() async throws {}
    func importFiles(_ urls: [URL]) async throws -> ResolvedModel { throw ModelStoreError.io("not available yet") }
    var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(AppInfo.name)/Models", isDirectory: true)
    }
}

extension SearchBackend {
    /// Stand-in for O4's `attachModel(_:)`: today's backend picks the model up at init, so this is a no-op.
    func attachModel(_ model: ResolvedModel) async {}
}

/// Stand-in for O3's `Crawler.appRoots`.
enum AppRoots {
    static var all: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true)]
    }
}
