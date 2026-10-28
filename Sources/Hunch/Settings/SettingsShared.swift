import AppKit
import Carbon.HIToolbox
import HunchCore
import Observation
import SwiftUI

/// The four Settings panes, in toolbar order (⌘1–⌘4). Persisted by raw value in `settings.pane`.
enum SettingsPane: String, CaseIterable, Sendable {
    case general, search, index, about

    var title: String {
        switch self {
        case .general: "General"
        case .search: "Search"
        case .index: "Index"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .search: "magnifyingglass"
        case .index: "internaldrive"
        case .about: "info.circle"
        }
    }

    static let defaultsKey = "settings.pane"

    /// The last pane the user picked, or General.
    static func restored(from defaults: UserDefaults) -> SettingsPane {
        defaults.string(forKey: defaultsKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// `.regular` while any of our titled windows is open (Settings, the guide), `.accessory` after the last closes.
@MainActor
enum ActivationPolicy {
    private static var open = Set<ObjectIdentifier>()

    static func windowOpened(_ window: NSWindow) {
        open.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // Every window here opens because the user asked (launch, reopen, a menu). At launch the cooperative
        // `activate()` was refused (2 of 2 runs), leaving Settings behind the front app until a second click; the
        // forced form activated in every run (macOS 27).
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed(_ window: NSWindow) {
        open.remove(ObjectIdentifier(window))
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// System Settings deep links.
enum SystemLinks {
    static let keyboardShortcuts = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let filesAndFolders = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let modelCard = URL(string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF")!
    static let apacheLicence = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!

    @MainActor static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: Shortcut recorder (Settings › General and the guide's step 2)

/// The hotkey recorder's state. One instance is shared by Settings and the guide, so both show the same chord.
@MainActor
@Observable
final class ShortcutRecorderModel {
    private(set) var shortcut: Shortcut
    private(set) var isRecording = false
    private(set) var error: String?
    /// The registration at launch failed: nothing is registered (no fallback chord, U4).
    private(set) var isUnregistered = false
    @ObservationIgnored private var monitor: Any?

    init() {
        shortcut = HotKey.shared.current ?? Shortcut.saved ?? .optionSpace
        #if DEBUG
        switch DebugOverrides.hotKeyState {
        case "reserved": error = HotKeyPolicy.reservedMessage
        case "recording": isRecording = true
        default: break
        }
        #endif
    }

    /// The saved or default chord could not be registered at launch.
    func reportConflict(_ s: Shortcut) {
        shortcut = s
        isUnregistered = true
        error = HotKeyPolicy.conflictMessage(s)
    }

    func toggleRecording() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) ?? false } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func record(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Escape), mods.isEmpty { stop(); return true }
        if event.keyCode == UInt16(kVK_Delete), mods.isEmpty {
            if apply(.optionSpace) { Shortcut.clearSaved() }
            stop()
            return true
        }
        guard let candidate = Shortcut(event: event) else {
            error = "Use ⌘, ⌥ or ⌃ with a key, or an F-key."
            return true
        }
        if HotKeyPolicy.isReservedBySystem(
            candidate, spotlightShortcutEnabled: HotKeyPolicy.systemSpotlightShortcutEnabled)
        {
            error = HotKeyPolicy.reservedMessage
            stop()
            return true
        }
        if apply(candidate) { candidate.save() }
        stop()
        return true
    }

    @discardableResult
    private func apply(_ candidate: Shortcut) -> Bool {
        if HotKey.shared.register(candidate) {
            shortcut = candidate
            error = nil
            isUnregistered = false
            return true
        }
        error = HotKeyPolicy.conflictMessage(candidate)
        return false
    }
}

extension Shortcut {
    /// VoiceOver name: "Option Space".
    var spokenName: String {
        var words: [String] = []
        if modifiers & UInt32(controlKey) != 0 { words.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { words.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { words.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { words.append("Command") }
        words.append(keycaps.last ?? "")
        return words.joined(separator: " ")
    }
}

/// M2.7 recorder: a bordered button showing the chord's keycaps; while recording "Type shortcut…" with a 2 pt
/// accent border. Esc cancels, Delete resets to ⌥Space.
struct ShortcutRecorder: View {
    let model: ShortcutRecorderModel

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            Group {
                if model.isRecording {
                    Text("Type shortcut…").foregroundStyle(.secondary)
                } else {
                    KeyCaps(caps: model.shortcut.keycaps, size: 12)
                }
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .overlay {
            if model.isRecording {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Shortcut, \(model.shortcut.spokenName)")
        .accessibilityHint(
            model.isRecording ? "Type the new shortcut. Escape cancels." : "Press to record a new shortcut")
    }
}

/// U8: the hotkey error row: triangle + red 11 pt text (the text carries the meaning, not the colour).
struct HotKeyErrorRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Model copy (guide step 4 and Settings › Index)

/// Every user-visible model string, pure so it is unit-testable.
enum ModelCopy {
    static let licence = "EmbeddingGemma 2 · Google DeepMind · Apache 2.0"
    static let downloadButton = "Download (865 MB)"

    static func megabytes(_ bytes: Int64) -> String {
        "\((Double(bytes) / 1_000_000).rounded().formatted(.number.precision(.fractionLength(0)))) MB"
    }

    static func gigabytes(_ bytes: Int64) -> String {
        "\((Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1)))) GB"
    }

    /// "about 2 min left", rounded up to the minute; "less than a minute left" under 60 s; nil before 3 s of samples.
    static func remaining(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        return "about \(minutes) min left"
    }

    static func progressCaption(_ p: DownloadProgress) -> String {
        var s = "\(megabytes(p.receivedBytes)) of \(megabytes(p.totalBytes))"
        if let left = remaining(p.secondsRemaining) { s += " · \(left)" }
        return s
    }

    static func pausedCaption(_ p: DownloadProgress) -> String {
        "Paused at \(megabytes(p.receivedBytes)) of \(megabytes(p.totalBytes))"
    }

    static func failure(_ e: ModelStoreError) -> String {
        switch e {
        case .offline: "You're offline. The download resumes when you're back online."
        case .checksum: "The download was damaged. Try again."
        case .diskFull(let needed, let available):
            "Not enough space. Free up \(gigabytes(max(needed - available, 0))) and try again."
        case .http, .io: "The download didn't finish. Try again."
        }
    }

    static func location(_ source: ModelSource) -> String {
        switch source {
        case .downloaded: "Downloaded"
        case .override: "Developer override"
        }
    }

    static func size(_ m: ResolvedModel) -> String { m.hasProjector ? "865 MB" : "296 MB, text only" }
}

/// The licence credit and its two links on one line (11 pt tertiary).
struct ModelLicenceLine: View {
    var body: some View {
        HStack(spacing: 12) {
            Text(ModelCopy.licence)
            Link("Model card", destination: SystemLinks.modelCard)
            Link("Licence", destination: SystemLinks.apacheLicence)
        }
        .lineLimit(1)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
}
