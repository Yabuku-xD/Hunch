import Testing

@testable import HunchCore

/// P2 with the real Russian, Greek and French (AZERTY) layout data installed on every Mac.
@MainActor @Suite struct ShortcutResolverTests {  // TIS input-source calls must run on the main thread
    var us: ShortcutResolver.KeyboardLayout? { ShortcutResolver.KeyboardLayout.installed("com.apple.keylayout.US") }
    // kVK_ANSI_K = 40, kVK_ANSI_C = 8, kVK_ANSI_O = 31, kVK_ANSI_Q = 12, kVK_ANSI_1 = 18, kVK_ANSI_8 = 28.

    /// What `layout` types for `keyCode`, resolved against the US ASCII layout.
    private func resolve(_ id: String, _ keyCode: UInt16) throws -> (typed: String, key: String) {
        let layout = try #require(ShortcutResolver.KeyboardLayout.installed(id), "\(id) not installed")
        let typed = try #require(layout.character(keyCode: keyCode))
        return (typed, ShortcutResolver.key(keyCode: keyCode, typed: typed, asciiLayout: us))
    }

    @Test(arguments: ["com.apple.keylayout.Russian", "com.apple.keylayout.Greek"])
    func nonLatinLettersMapToPhysicalKey(_ id: String) throws {
        for (code, letter) in [(UInt16(40), "k"), (8, "c"), (31, "o")] {
            let r = try resolve(id, code)
            let latin = r.typed.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(!latin, "\(id) types \(r.typed) for \(code)")
            #expect(r.key == letter, "\(id): ⌘\(r.typed) should act as ⌘\(letter)")
        }
    }

    @Test func azertyKeepsItsOwnLetters() throws {
        let q = try resolve("com.apple.keylayout.French", 12)  // AZERTY: the QWERTY Q key types "a"
        #expect(q.typed == "a" && q.key == "a")
        let a = try resolve("com.apple.keylayout.French", 0)  // and the QWERTY A key types "q"
        #expect(a.key == "q")
    }

    @Test(arguments: ["com.apple.keylayout.Russian", "com.apple.keylayout.Greek", "com.apple.keylayout.French"])
    func digitsByKeyCodeOnEveryLayout(_ id: String) throws {
        // AZERTY types "&" on the 1 key; the key code still means 1.
        _ = try resolve(id, 18)
        #expect(ShortcutResolver.digit(keyCode: 18) == 1)
        #expect(ShortcutResolver.digit(keyCode: 28) == 8)
        #expect(ShortcutResolver.digit(keyCode: 25) == nil)  // kVK_ANSI_9 is not a slot
    }
}
