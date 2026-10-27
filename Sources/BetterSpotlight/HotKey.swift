import AppKit
import Carbon.HIToolbox

/// A global key chord in Carbon terms (virtual key code + Carbon modifier mask), persisted in UserDefaults.
struct Shortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    private static let keyCodeKey = "hotkey.keyCode"
    private static let modifiersKey = "hotkey.modifiers"

    static var saved: Shortcut? {
        let defaults = AppDefaults.store
        guard defaults.object(forKey: keyCodeKey) != nil else { return nil }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                        modifiers: UInt32(defaults.integer(forKey: modifiersKey)))
    }

    func save() {
        AppDefaults.store.set(Int(keyCode), forKey: Self.keyCodeKey)
        AppDefaults.store.set(Int(modifiers), forKey: Self.modifiersKey)
    }

    static func clearSaved() {
        AppDefaults.store.removeObject(forKey: keyCodeKey)
        AppDefaults.store.removeObject(forKey: modifiersKey)
    }

    /// From a key-down event; nil unless it has ⌘, ⌥ or ⌃, or is an F-key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let hasChordModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        guard hasChordModifier || Self.functionKeys[code] != nil else { return nil }
        self.init(keyCode: code, modifiers: carbon)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Keycap strings in macOS order: ⌃ ⌥ ⇧ ⌘ then the key.
    var keycaps: [String] {
        var caps: [String] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { caps.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { caps.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { caps.append("⌘") }
        caps.append(keyName)
        return caps
    }

    var displayString: String { keycaps.joined() }

    private var keyName: String {
        if let name = Self.namedKeys[keyCode] { return name }
        if let f = Self.functionKeys[keyCode] { return f }
        // Translate through the current keyboard layout so ⌥Q on AZERTY reads "A", not "Q".
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return -1
                }
                return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                      UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                      &dead, 4, &length, &chars)
            }
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "Key \(keyCode)"
    }

    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↵", UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
    ]

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
    ]
}

/// The one global hotkey, via Carbon `RegisterEventHotKey` (needs no Accessibility permission). Re-registering
/// installs the new chord first and drops the old one only if that succeeded, so a taken chord never loses the old one.
@MainActor
final class HotKey {
    static let shared = HotKey()

    private(set) var current: Shortcut?
    /// Called on the main thread from the Carbon handler.
    var action: (() -> Void)?
    /// When set (onboarding step 2 is key), a press goes here instead of `action` ("Works" test line).
    var interceptor: (() -> Bool)?
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var nextID: UInt32 = 1

    private init() {}

    /// Returns false when the chord is already taken (the previous chord stays registered).
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if shortcut == current, hotKeyRef != nil { return true }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var ref: EventHandlerRef?
            guard InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, &ref) == noErr else {
                return false
            }
            handlerRef = ref
        }
        #if DEBUG
        if DebugOverrides.hotKeyState == "conflict" { return false }
        #endif
        nextID &+= 1
        let id = EventHotKeyID(signature: OSType(0x4253_7074), id: nextID) // 'BSpt'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = ref
        current = shortcut
        return true
    }

    fileprivate func fire() {
        #if DEBUG
        Measure.shared.hotKeyPressed()
        #endif
        if let interceptor, interceptor() { return }
        action?()
    }
}

/// Carbon delivers application-target events on the main thread.
private func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKey.shared.fire() }
    return noErr
}
