import Foundation

/// K7: extra name keys for an item, computed off-main at index time only (never per keystroke):
/// - apps: CFBundleDisplayName / CFBundleName (non-empty) from Info.plist and the localized values from
///   `<lang>.lproj/InfoPlist.strings` or `InfoPlist.loctable`, along the fallback chain full tag → language-script →
///   language (`nb`↔`no`); no MDItem calls;
/// - Han names (any item): a full pinyin key and an initials key ("终端" → "zhongduan", "zd").
/// NameIndex stores each key as an extra row pointing at the same item id; results are de-duplicated by id.
public enum AppNames {
    /// All alias keys for `item` (excluding its own name).
    public static func keys(for item: Item, languages: [String]? = nil) -> [String] {
        var out: [String] = []
        if item.kind == .app || item.path.hasSuffix(".app") {
            out += aliases(bundle: URL(fileURLWithPath: item.path, isDirectory: true),
                           languages: languages ?? preferredLanguages)
        }
        // Fast path: the common case (no app, no Han) allocates nothing.
        guard !out.isEmpty || !item.name.utf8.allSatisfy({ $0 < 0x80 }) else { return [] }
        for name in [item.name] + out { out += pinyinKeys(name) }
        let own = (item.name as NSString).deletingPathExtension.lowercased()
        var seen: Set<String> = [own, item.name.lowercased()]
        return out.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Read once per process: `Locale.preferredLanguages` costs a preferences lookup per call (100k items at
    /// launch). A language change takes effect on the next launch (the names.bin generation includes it).
    static let preferredLanguages = Locale.preferredLanguages

    /// Display names of the bundle at `bundle`: Info.plist values, then the first localization found per language.
    public static func aliases(bundle: URL, languages: [String]) -> [String] {
        let contents = bundle.appendingPathComponent("Contents")
        let infoURL = FileManager.default.fileExists(atPath: contents.path)
            ? contents.appendingPathComponent("Info.plist") : bundle.appendingPathComponent("Info.plist")
        let resources = FileManager.default.fileExists(atPath: contents.path)
            ? contents.appendingPathComponent("Resources") : bundle
        var out: [String] = []
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        if let info = plist(infoURL) {
            for k in keys { if let v = info[k] as? String { out.append(v) } }
        }
        let loctable = plist(resources.appendingPathComponent("InfoPlist.loctable"))
        for lang in languages {
            for tag in chain(lang) {
                var table = plist(resources.appendingPathComponent("\(tag).lproj/InfoPlist.strings"))
                if table == nil { table = loctable?[tag] as? [String: Any] }
                guard let table else { continue }
                for k in keys { if let v = table[k] as? String { out.append(v) } }
                break
            }
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// "zh-Hans-CN" → ["zh-Hans-CN", "zh-Hans", "zh"]; "nb-NO" → [..., "nb", "no"]; also `_` spellings.
    static func chain(_ tag: String) -> [String] {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first else { return [] }
        var out: [String] = []
        for n in stride(from: parts.count, through: 1, by: -1) {
            let t = parts.prefix(n).joined(separator: "-")
            out.append(t)
            if n > 1 { out.append(parts.prefix(n).joined(separator: "_")) }
        }
        if lang == "nb" { out.append("no") } else if lang == "no" { out.append("nb") }
        if lang == "en" { out.append("English") }
        return out
    }

    /// Full pinyin (no spaces, no tones) and initials for names containing Han characters.
    public static func pinyinKeys(_ name: String) -> [String] {
        guard name.unicodeScalars.contains(where: isHan) else { return [] }
        let stem = (name as NSString).deletingPathExtension
        guard let latin = stem.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() else { return [] }
        let syllables = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !syllables.isEmpty else { return [] }
        return [syllables.joined(), String(syllables.compactMap(\.first))]
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: true
        default: false
        }
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
