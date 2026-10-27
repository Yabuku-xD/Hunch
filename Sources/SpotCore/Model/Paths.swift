import Foundation

/// Well-known locations.
public struct Paths: Sendable {
    /// ~/Library/Application Support/BetterSpotlight
    public static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterSpotlight", isDirectory: true)
    }

    /// The resolved embedding model, or the DigUp path when nothing is found (loading it then fails cleanly).
    public static var modelURL: URL {
        resolveModel() ?? digUpModel(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// EmbeddingGemma 2 text gguf, resolved by `ModelStore` (exact pinned names, in `ModelSource` order:
    /// env `BS_MODEL` → our Models folder → Hugging Face cache → DigUp's copy). nil = name-only mode.
    public static func resolveModel(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        ModelStore(home: home, environment: environment).resolve()?.text
    }

    /// The vision projector (`mmproj-embeddinggemma-2-Q8_0.gguf`, or env `BS_MMPROJ`) for image embedding, as
    /// `ModelStore` resolves it. `model` is kept for source compatibility; the store pairs files by name, not folder.
    public static func resolveProjector(for model: URL,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        ModelStore(environment: environment).resolve()?.projector
    }

    static func digUpModel(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/DigUp/Models/embeddinggemma-2-Q8_0.gguf")
    }
}
