import AppKit
import SwiftUI

/// DEBUG-only stand-ins for the system accessibility switches, so every Reduce Transparency / Increase Contrast /
/// Reduce Motion path can be screenshotted without touching `com.apple.universalaccess`:
/// `HUNCH_REDUCE_TRANSPARENCY=1`, `HUNCH_INCREASE_CONTRAST=1`, `HUNCH_REDUCE_MOTION=1`, and `HUNCH_APPEARANCE=light|dark`
/// (this app only, the system appearance is left alone). Release builds read the real settings only.
enum DebugOverrides {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment
    static let reduceTransparency = env["HUNCH_REDUCE_TRANSPARENCY"] == "1"
    static let increaseContrast = env["HUNCH_INCREASE_CONTRAST"] == "1"
    static let reduceMotion = env["HUNCH_REDUCE_MOTION"] == "1"
    static let exp = env["HUNCH_EXP"] ?? ""

    // v4 §6 screenshot overrides, read once at launch. None of these strings exist in a release binary.
    static let screen: FakeScreen? = env["HUNCH_SCREEN"].flatMap(FakeScreen.init(spec:))
    static let screenOutline = env["HUNCH_SCREEN_OUTLINE"] == "1"
    static let onboardingStep: Int? = env["HUNCH_ONBOARDING_STEP"].flatMap(Int.init).map { min(max($0, 1), 5) }
    static let firstRun = env["HUNCH_FIRST_RUN"] == "1" || onboardingStep != nil
    static let welcome = ProcessInfo.processInfo.arguments.contains("--welcome")
    static let settingsPane: String? = env["HUNCH_SETTINGS_PANE"]
    static let modelState: String? = env["HUNCH_MODEL_STATE"]
    static let modelFrozen = env["HUNCH_MODEL_FROZEN"] == "1"
    static let hotKeyState: String? = env["HUNCH_HOTKEY_STATE"]
    static let spotlightShortcut: Bool? = env["HUNCH_SPOTLIGHT_SHORTCUT"].map { $0 == "on" }
    static let fixtureFolderCounts = env["HUNCH_FOLDER_COUNTS"] == "fixture"
    static let tccResult: String? = env["HUNCH_TCC_RESULT"]
    static let indexState: String? = env["HUNCH_INDEX_STATE"]
    static let hoverRow: Int? = env["HUNCH_HOVER_ROW"].flatMap(Int.init)
    static let press: String? = env["HUNCH_PRESS"]
    @MainActor static var appearance: NSAppearance? {
        switch env["HUNCH_APPEARANCE"] {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
    #else
    static let reduceTransparency = false
    static let increaseContrast = false
    static let reduceMotion = false
    @MainActor static var appearance: NSAppearance? { nil }
    static let press: String? = nil
    #endif

    @MainActor static var systemReduceTransparency: Bool {
        reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    @MainActor static var systemReduceMotion: Bool {
        reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor static var systemIncreaseContrast: Bool {
        increaseContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// The defaults store for `onboarding.*`, `hint.*`, `hotkey.*` and `settings.pane`. DEBUG `HUNCH_FIRST_RUN=1` swaps in a
/// volatile suite cleared at launch, so the guide shows as on a fresh install and real prefs stay untouched.
enum AppDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if DebugOverrides.firstRun, let suite = UserDefaults(suiteName: "bs.debug.firstrun") {
            suite.removePersistentDomain(forName: "bs.debug.firstrun")
            return suite
        }
        #endif
        return .standard
    }()
}

extension View {
    /// Applies the DEBUG overrides to SwiftUI's environment (no-op in release).
    @ViewBuilder func debugAccessibilityOverrides() -> some View {
        #if DEBUG
        self
            .transformEnvironment(\._accessibilityReduceTransparency) {
                if DebugOverrides.reduceTransparency { $0 = true }
            }
            .transformEnvironment(\._accessibilityReduceMotion) { if DebugOverrides.reduceMotion { $0 = true } }
            .transformEnvironment(\._colorSchemeContrast) { if DebugOverrides.increaseContrast { $0 = .increased } }
        #else
        self
        #endif
    }
}
