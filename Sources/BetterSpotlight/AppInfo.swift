import Foundation

/// The one place the product name lives (v4 D1): a rename is this constant plus Scripts.
enum AppInfo {
    static let name = "BetterSpotlight"
    /// CFBundleShortVersionString, or "dev" outside the app bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    static let repoURL = URL(string: "https://github.com/Yabuku-xD/BetterSpotlight")!
    static var releasesURL: URL { repoURL.appendingPathComponent("releases/latest") }
}
