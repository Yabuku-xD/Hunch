import Foundation
import UniformTypeIdentifiers

/// K17: scope operators inside the query. Only `name:`, `in:`, `ext:` and `kind:` with a non-empty value are
/// operators; anything else (`a:b.txt`, `kind:foo`) stays plain text, so ordinary queries never change meaning.
///
///     name:invoice           names only (no full-text, no semantic leg)
///     in:Downloads           at or below ~/Downloads (absolute and ~ paths too; quotes for spaces: in:"My Stuff")
///     ext:pdf                by extension (repeatable: ext:pdf ext:md)
///     kind:app|folder|file|image|video|audio|doc
public struct ParsedQuery: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case app, folder, file, image, video, audio, doc }

    /// What is left to search for, operators removed.
    public var text: String
    public var nameOnly = false
    /// Canonical absolute folder paths from `in:`.
    public var folders: [String] = []
    /// Lowercased, without the dot.
    public var extensions: Set<String> = []
    public var kinds: Set<Kind> = []

    public init(text: String, nameOnly: Bool = false, folders: [String] = [], extensions: Set<String> = [],
                kinds: Set<Kind> = []) {
        self.text = text
        self.nameOnly = nameOnly
        self.folders = folders
        self.extensions = extensions
        self.kinds = kinds
    }

    /// True when a filter narrows the results (not counting `name:`).
    public var hasFilters: Bool { !folders.isEmpty || !extensions.isEmpty || !kinds.isEmpty }

    /// Whether `item` passes every filter.
    public func matches(_ item: Item) -> Bool {
        if !folders.isEmpty, !folders.contains(where: { Self.isAtOrBelow(item.path, $0) }) { return false }
        let ext = (item.path as NSString).pathExtension.lowercased()
        if !extensions.isEmpty, !extensions.contains(ext) { return false }
        if !kinds.isEmpty, !kinds.contains(where: { Self.kind($0, matches: item, ext: ext) }) { return false }
        return true
    }

    static func isAtOrBelow(_ path: String, _ folder: String) -> Bool {
        path == folder || (path.hasPrefix(folder) && path.utf8.dropFirst(folder.utf8.count).first == UInt8(ascii: "/"))
            || folder == "/"
    }

    private static func kind(_ k: Kind, matches item: Item, ext: String) -> Bool {
        switch k {
        case .app: return item.kind == .app
        case .folder: return item.kind == .folder
        case .file: return item.kind == .file
        case .image, .video, .audio, .doc:
            guard item.kind == .file, !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
            switch k {
            case .image: return type.conforms(to: .image)
            case .video: return type.conforms(to: .movie) || type.conforms(to: .video)
            case .audio: return type.conforms(to: .audio)
            default:
                return type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .compositeContent)
                    || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            }
        }
    }
}

public enum QueryParser {
    /// Parses `query`. `home` resolves relative `in:` folders (`in:Downloads` → `<home>/Downloads`).
    public static func parse(_ query: String,
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> ParsedQuery {
        var out = ParsedQuery(text: "")
        var rest: [String] = []
        for token in tokens(query) {
            guard let colon = token.firstIndex(of: ":") else { rest.append(token); continue }
            let key = token[..<colon].lowercased()
            var value = String(token[token.index(after: colon)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "name" where !value.isEmpty:
                out.nameOnly = true
                rest.append(value)
            case "in" where !value.isEmpty:
                out.folders.append(folder(value, home: home))
            case "ext" where !value.isEmpty:
                for e in value.split(separator: ",") {
                    out.extensions.insert(e.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                }
            case "kind":
                if let k = ParsedQuery.Kind(rawValue: value.lowercased()) { out.kinds.insert(k) } else { rest.append(token) }
            default:
                rest.append(token)
            }
        }
        out.text = rest.joined(separator: " ")
        return out
    }

    /// Whitespace-separated tokens; `"…"` after an operator's colon keeps spaces (`in:"My Stuff"`).
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); cur.append(ch); continue }
            if ch.isWhitespace && !quoted {
                if !cur.isEmpty { out.append(cur) }
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func folder(_ value: String, home: String) -> String {
        var p = value
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst() } else if !p.hasPrefix("/") {
            p = home + "/" + p
        }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return PathKey.canonical(p)
    }
}
