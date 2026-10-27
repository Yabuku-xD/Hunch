import Foundation

/// K1: the content side of the index, built by `SearchBackend.start()` itself (the app only flips
/// `IndexSettings.contentIndexing`). One full-text index + one queue-backed pipeline, sharing the backend's lazily
/// loaded text embedder and vector store; the image model (mmproj) is its own lazy actor that maps only while
/// tier-2/3 work is pending (K12d). spot-bench builds the same thing, so the bench measures what ships.
public final class ContentRuntime: Sendable {
    public let fullText: FullTextIndex
    public let pipeline: ContentIndexPipeline
    /// nil without a model (OCR / transcripts / full text still run).
    public let media: ManagedMediaEmbedder?

    /// - Parameters:
    ///   - directory: where `content.sqlite` and `content-queue.sqlite` live (the backend's directory).
    ///   - embedder/vectors: shared with the name index; nil = full text only, no content vectors.
    ///   - modelURL: the text gguf the image model pairs with; nil = no image vectors.
    ///   - projectorURL: the mmproj that embeds images (from `ModelStore.resolve()`); nil = the store's lookup.
    public init(directory: URL, embedder: (any Embedder)?, vectors: (any VectorIndex)?, modelURL: URL?,
                projectorURL: URL? = nil, dimension: Int = 256, policy: ContentIndexPipeline.Policy = .system,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        fullText = try FullTextIndex(url: directory.appendingPathComponent("content.sqlite"))
        media = modelURL.map {
            ManagedMediaEmbedder.standard(modelURL: $0, projectorURL: projectorURL, dimension: dimension)
        }
        pipeline = try ContentIndexPipeline(fullText: fullText,
                                            queueURL: directory.appendingPathComponent("content-queue.sqlite"),
                                            media: media, embedder: embedder, vectors: vectors, policy: policy,
                                            home: home)
    }

    public func start() async { await pipeline.start() }
    public func stop() async { await pipeline.stop() }
}
