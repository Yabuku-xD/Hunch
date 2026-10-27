import Carbon
import Foundation

/// P2: shortcut letters by physical key on non-Latin layouts, digits by key code on every layout. Pure apart from
/// the injected layout, so Russian / Greek / AZERTY behaviour is unit-tested with the real layout data.
public enum ShortcutResolver {
    /// One keyboard layout's `uchr` data.
    public struct KeyboardLayout: Sendable {
        let data: Data

        /// The user's current ASCII-capable layout (what ⌘-shortcuts resolve against).
        public static var currentASCIICapable: KeyboardLayout? {
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap { layout($0.takeRetainedValue()) }
        }

        /// An installed layout by input source id, e.g. "com.apple.keylayout.Russian" (enabled or not).
        public static func installed(_ id: String) -> KeyboardLayout? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
                let source = list.first
            else { return nil }
            return layout(source)
        }

        private static func layout(_ source: TISInputSource) -> KeyboardLayout? {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return KeyboardLayout(data: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data)
        }

        /// The unmodified character `keyCode` types on this layout (lowercased).
        public func character(keyCode: UInt16) -> String? {
            data.withUnsafeBytes { buffer -> String? in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length,
                    &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length).lowercased()
            }
        }
    }

    /// kVK_ANSI_1 … kVK_ANSI_8 (and the keypad 1…8).
    private static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8,
    ]

    public static func digit(keyCode: UInt16) -> Int? { digits[keyCode] }

    /// The typed character when it is ASCII (QWERTY, AZERTY, Dvorak … keep their own letters); otherwise the
    /// character of the same key on the ASCII-capable layout (Russian/Greek/Hebrew …).
    public static func key(
        keyCode: UInt16, typed: String?,
        asciiLayout: @autoclosure () -> KeyboardLayout? = .currentASCIICapable
    ) -> String {
        let typed = typed?.lowercased() ?? ""
        if typed.isEmpty || typed.unicodeScalars.allSatisfy(\.isASCII) { return typed }
        return asciiLayout()?.character(keyCode: keyCode) ?? typed
    }
}
