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

    /// Hunch's own folder in the home directory: `~/.hunch`.
    public static func dotFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".hunch", isDirectory: true)
    }

    /// Where the model is downloaded and loaded from: `~/.hunch/models`.
    public static func modelsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        dotFolder(home: home).appendingPathComponent("models", isDirectory: true)
    }

    /// Up to 1.1.0 the model lived in `~/Library/Application Support/Hunch/Models`. Moves those files (model, partial
    /// downloads, checksum cache) to `~/.hunch/models` once, so an update does not download 865 MB again. A rename on
    /// the same volume: no copy, no extra disk space. Does nothing once the old folder is gone.
    public static func migrateModelsToDotFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let fm = FileManager.default
        let old = home.appendingPathComponent("Library/Application Support/Hunch/Models", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        let new = modelsDirectory(home: home)
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in names where !fm.fileExists(atPath: new.appendingPathComponent(name).path) {
            try? fm.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty ?? false { try? fm.removeItem(at: old) }
    }

    /// The resolved embedding model, or its download path when it is missing (loading it then fails cleanly).
    public static var modelURL: URL {
        resolveModel() ?? modelsDirectory().appendingPathComponent(ModelFile.text.fileName)
    }

    /// EmbeddingGemma 2 text gguf, resolved by `ModelStore` (exact pinned name: env `HUNCH_MODEL`, then
    /// `~/.hunch/models`). nil = name-only mode.
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
}
