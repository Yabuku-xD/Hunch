import Carbon.HIToolbox
import Foundation

/// U4: which chords macOS owns by default, and what the recorder says about them. Pure, so it is unit-testable.
enum HotKeyPolicy {
    private static let space = UInt32(kVK_Space)
    private static let tab = UInt32(kVK_Tab)
    private static let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey)

    static let commandSpace = Shortcut(keyCode: space, modifiers: cmd)
    /// ⌘Space (Spotlight), ⌃Space (input sources), ⌥⌘Space (Finder search window), ⌃⌘Space (character viewer), ⌘Tab.
    static let reserved: [Shortcut] = [
        commandSpace,
        Shortcut(keyCode: space, modifiers: ctrl),
        Shortcut(keyCode: space, modifiers: opt | cmd),
        Shortcut(keyCode: space, modifiers: ctrl | cmd),
        Shortcut(keyCode: tab, modifiers: cmd),
    ]

    static let reservedMessage = "Used by macOS. Pick another shortcut."

    /// `spotlightShortcutEnabled`: ⌘Space is allowed once the user has turned off Spotlight's own shortcut.
    static func isReservedBySystem(_ s: Shortcut, spotlightShortcutEnabled: Bool = true) -> Bool {
        if s == commandSpace, !spotlightShortcutEnabled { return false }
        return reserved.contains(s)
    }

    static func conflictMessage(_ s: Shortcut) -> String {
        "\(s.displayString) is used by another app. Pick another shortcut."
    }

    /// Reads `com.apple.symbolichotkeys` key 64 ("Show Spotlight search"). Best effort and read-only: unreadable
    /// counts as enabled.
    static func spotlightShortcutEnabled(_ hotkeys: [String: Any]?) -> Bool {
        guard let entry = hotkeys?["64"] as? [String: Any], let enabled = entry["enabled"] else { return true }
        return (enabled as? Bool) ?? ((enabled as? NSNumber)?.boolValue ?? true)
    }

    static var systemSpotlightShortcutEnabled: Bool {
        #if DEBUG
        if let fake = DebugOverrides.spotlightShortcut { return fake }
        #endif
        return spotlightShortcutEnabled(
            UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"))
    }
}
