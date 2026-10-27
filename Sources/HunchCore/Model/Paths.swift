import Foundation

/// Well-known locations.
public struct Paths: Sendable {
    /// ~/Library/Application Support/Hunch
    public static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hunch", isDirectory: true)
    }

    /// 1.0.0 shipped as "BetterSpotlight". Moves its index and models to the Hunch folder once, so an update keeps
    /// the index and the 865 MB model. Safe to call on every launch: it does nothing once the new folder exists.
    public static func migrateLegacyAppSupport(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let old = support.appendingPathComponent("BetterSpotlight", isDirectory: true)
        let new = support.appendingPathComponent("Hunch", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    /// The resolved embedding model, or the DigUp path when nothing is found (loading it then fails cleanly).
    public static var modelURL: URL {
        resolveModel() ?? digUpModel(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// EmbeddingGemma 2 text gguf, resolved by `ModelStore` (exact pinned names, in `ModelSource` order:
    /// env `HUNCH_MODEL` → our Models folder → Hugging Face cache → DigUp's copy). nil = name-only mode.
    public static func resolveModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        ModelStore(home: home, environment: environment).resolve()?.text
    }

    /// The vision projector (`mmproj-embeddinggemma-2-Q8_0.gguf`, or env `HUNCH_MMPROJ`) for image embedding, as
    /// `ModelStore` resolves it. `model` is kept for source compatibility; the store pairs files by name, not folder.
    public static func resolveProjector(
        for model: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        ModelStore(environment: environment).resolve()?.projector
    }

    static func digUpModel(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/DigUp/Models/embeddinggemma-2-Q8_0.gguf")
    }
}
