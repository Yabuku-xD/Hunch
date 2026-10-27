import Foundation
import IOKit.ps

/// System Settings panes: ExtensionKit extensions at the Settings UI extension point. They are indexed like apps
/// (kind `.setting`, the pane's display name) and open through `x-apple.systempreferences:<bundle id>`.
public enum SettingsPanes {
    static let directory = "/System/Library/ExtensionKit/Extensions"
    static let extensionPoint = "com.apple.Settings.extension.ui"
    /// The app whose icon a pane row shows.
    public static let app = "/System/Applications/System Settings.app"

    /// One entry per pane that System Settings opens by URL (~50 on macOS 26/27). Reads each Info.plist once, at crawl
    /// time only.
    static func entries(
        directory: String = directory, languages: [String] = AppNames.preferredLanguages
    )
        -> [CrawlEntry]
    {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".appex") }.sorted().compactMap { name in
            let path = directory + "/" + name
            guard let info = settingsInfo(path), var entry = Crawler.entry(at: path) else { return nil }
            entry.kind = .setting
            entry.name = title(path: path, info: info, languages: languages)
            return entry
        }
    }

    /// `x-apple.systempreferences:<bundle id>` for the pane at `path`.
    public static func url(forPane path: String) -> URL? {
        guard let id = info(path)?["CFBundleIdentifier"] as? String else { return nil }
        return URL(string: "x-apple.systempreferences:\(id)")
    }

    /// Topic titles from the pane's search terms ("Touch Bar", "Battery Health"), for the name index.
    public static func aliases(path: String, languages: [String]) -> [String] {
        guard let info = settingsInfo(path), let file = attributes(info)?["searchTermsFileName"] as? String else {
            return []
        }
        let resources = path + "/Contents/Resources/"
        let tags = languages.flatMap(AppNames.chain) + ["en", "Base", ""]
        guard
            let table = tags.lazy.compactMap({ tag in
                plist(resources + (tag.isEmpty ? "" : tag + ".lproj/") + file + ".searchTerms")
            }).first
        else { return [] }
        var titles: [String] = []
        for case let group as [String: Any] in table.values {
            for case let entry as [String: Any] in group["localizableStrings"] as? [Any] ?? [] {
                if let t = entry["title"] as? String { titles.append(t) }
            }
        }
        return titles + representationNames(path: path, info: info, languages: languages).map(\.title)
    }

    /// Panes with several sidebar names ("Battery" on a laptop, "Energy" on a desktop), resolved through the bundle's
    /// string tables. `matches`: no predicate, or a power-source predicate that holds on this Mac.
    struct SidebarName { let title: String; let matches: Bool }

    static func representationNames(path: String, info: [String: Any], languages: [String]) -> [SidebarName] {
        guard let reps = attributes(info)?["representations"] as? [[String: Any]] else { return [] }
        let resources = path + "/Contents/Resources/"
        let tables = ((try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? [])
            .filter { $0.hasSuffix(".loctable") }.sorted().compactMap { plist(resources + $0) }
        let tags = languages.flatMap(AppNames.chain) + ["en"]
        return reps.compactMap { rep in
            guard let key = rep["sidebar-name"] as? String, rep["hidden"] as? Bool != true else { return nil }
            let localized = tags.lazy.compactMap { tag in
                tables.lazy.compactMap { ($0[tag] as? [String: Any])?[key] as? String }.first
            }.first
            let predicate = rep["predicate"] as? String ?? ""
            // Only the power-source predicate is evaluated; others (Touch ID, guest) leave the last name as default.
            var matches = predicate.isEmpty
            if predicate.contains("powersource.battery") {
                matches = predicate.contains("!=") != hasInternalBattery
            }
            return SidebarName(title: clean(localized ?? key), matches: matches)
        }
    }

    /// Whether this Mac has a built-in battery (a laptop).
    static let hasInternalBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return d?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    /// Non-breaking hyphens ("Wi‑Fi") become plain ones, so typing "wi-fi" matches.
    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\u{2011}", with: "-") }

    /// The pane's name as the System Settings sidebar shows it, as far as the bundle says.
    static func title(path: String, info: [String: Any], languages: [String]) -> String {
        if let alt = attributes(info)?["alt_name"] as? String, !alt.isEmpty { return clean(alt) }
        let names = representationNames(path: path, info: info, languages: languages)
        if let name = names.first(where: \.matches) ?? names.last { return name.title }
        let resources = path + "/Contents/Resources/"
        let loctable = plist(resources + "InfoPlist.loctable")
        for tag in languages.flatMap(AppNames.chain) + ["en"] {
            let table = plist(resources + tag + ".lproj/InfoPlist.strings") ?? loctable?[tag] as? [String: Any]
            if let name = table?["CFBundleDisplayName"] as? String, !name.isEmpty { return clean(name) }
        }
        let raw =
            info["CFBundleDisplayName"] as? String
            ?? ((path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        return clean(humanize(raw))
    }

    /// "HeadphoneSettingsExtension" → "Headphone", "PowerPreferences" → "Power"; names with spaces stay.
    static func humanize(_ raw: String) -> String {
        guard !raw.contains(" ") else { return raw }
        var stem = raw
        for suffix in ["SettingsExtension", "PreferenceExtension", "Extension", "Settings", "Preferences", "Ext"]
        where stem.hasSuffix(suffix) && stem.count > suffix.count {
            stem.removeLast(suffix.count)
        }
        var out = ""
        for (i, ch) in stem.enumerated() {
            if i > 0, ch.isUppercase, let prev = out.last, prev.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    private static func settingsInfo(_ path: String) -> [String: Any]? {
        guard let info = info(path), let ext = info["EXAppExtensionAttributes"] as? [String: Any],
            ext["EXExtensionPointIdentifier"] as? String == extensionPoint,
            attributes(info)?["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
        else { return nil }
        return info
    }

    private static func attributes(_ info: [String: Any]) -> [String: Any]? {
        (info["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"] as? [String: Any]
    }

    private static func info(_ path: String) -> [String: Any]? { plist(path + "/Contents/Info.plist") }

    private static func plist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
