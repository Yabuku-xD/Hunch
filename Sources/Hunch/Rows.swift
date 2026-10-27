import AppKit
import HunchCore
import UniformTypeIdentifiers

/// Result groups in display order. Groups have no header rows: each is named by a glyph in the gutter (and by
/// VoiceOver). Meaning is always last, so late semantic batches only ever append at the tail.
enum DisplayGroup: Int, Hashable, Comparable, Sendable, CaseIterable {
    case favorites, recents, topHit, apps, folders, files, text, images, video, audio, meaning

    static func < (a: DisplayGroup, b: DisplayGroup) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .recents: "Recents"
        case .topHit: "Top Hit"
        case .apps: "Applications"
        case .folders: "Folders"
        case .files: "Files"
        case .text: "Text in documents"
        case .images: "Text in images"
        case .video: "Videos"
        case .audio: "Speech"
        case .meaning: "Matches by meaning"
        }
    }

    /// Plural noun for "Show all 9,412 Files" and "Showing videos only".
    var noun: String {
        switch self {
        case .favorites: "Favorites"
        case .recents: "Recents"
        case .topHit: "Results"
        case .apps: "Apps"
        case .folders: "Folders"
        case .files: "Files"
        case .text: "Documents"
        case .images: "Images"
        case .video: "Videos"
        case .audio: "Recordings"
        case .meaning: "Meaning Matches"
        }
    }

    /// Gutter glyph (SF Symbol). Meaning uses the typographic `≈` instead (see `isMeaning`).
    var symbol: String {
        switch self {
        case .favorites: "pin"
        case .recents: "clock"
        case .topHit: "arrow.turn.down.left"
        case .apps: "app"
        case .folders: "folder"
        case .files: "doc"
        case .text: "text.alignleft"
        case .images: "photo"
        case .video: "play"
        case .audio: "waveform"
        case .meaning: "equal"
        }
    }

    var isMeaning: Bool { self == .meaning }
}

enum RowID: Hashable, Sendable {
    case item(UInt32)
    case rail
    case showAll(DisplayGroup)
    case finder
}

/// One fixed-pitch slot in the results list. Its height depends on the row type only, never on selection, so
/// moving the slip only changes which lanes the glass cuts open; nothing moves.
struct Row: Identifiable {
    enum Content {
        case name(SearchResult)
        case evidence(SearchResult)
        case rail([SearchResult])
        case showAll(DisplayGroup, Int)
        case finder(String)
    }

    let id: RowID
    let content: Content
    let group: DisplayGroup
    /// Top of the content box in list coordinates.
    let y: CGFloat
    /// Content height (the 4 pt lane follows it).
    let height: CGFloat
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    /// U6: the title line's strings, built once per batch for the first screen of rows (nil: built in the body).
    var text: RowText?

    var result: SearchResult? {
        switch content {
        case .name(let r), .evidence(let r): r
        default: nil
        }
    }
}

/// A name row's title line, prepared off the view body: the highlighted title, the location candidates, the location
/// a non-slip row shows (picked by cached widths) and the kind label.
struct RowText: Equatable {
    let title: AttributedString
    let locations: [String]
    let location: String?
    let kind: String

    @MainActor
    static func make(_ result: SearchResult, query: String, theme: Theme, underline: Bool = false) -> RowText {
        let locations = DisplayText.locations(result.item)
        return RowText(
            title: MatchHighlight.title(
                DisplayText.name(result.item), query: query, size: theme.titleSize,
                underline: underline),
            locations: locations,
            location: locations.isEmpty ? nil : LocationFit.choose(locations, result: result, theme: theme),
            kind: KindLabel.text(for: result.item))
    }
}

/// What the list says besides rows: no results, or exactly one match.
struct ListMessage: Equatable {
    var title: String
    var detail: String?
    /// U10: "Searched N folders · Add folders in Settings (⌘,)"; clicking it opens Settings › Search.
    var footnote: String?
}

/// U12/F24: the search spinner appears after 150 ms and, once shown, stays at least 300 ms. Pure (unit-tested).
enum SpinnerPolicy {
    static let showDelay: Double = 0.15
    static let minVisible: Double = 0.3

    /// The earliest instant the spinner may hide, given when it was shown and when the work finished.
    static func hideAt(shownAt: Double, finishedAt: Double) -> Double {
        max(finishedAt, shownAt + minVisible)
    }
}

extension SearchResult {
    /// Natural group of a result, ignoring Top Hit.
    var naturalGroup: DisplayGroup {
        if let match, source == .content || source == .semantic {
            switch match.kind {
            case .text: return .text
            case .ocr: return FileKind.of(item.path) == .video ? .video : .images
            case .transcript: return FileKind.of(item.path) == .video ? .video : .audio
            case .semantic, .image: return .meaning
            }
        }
        if source == .semantic { return .meaning }
        switch item.kind {
        case .app, .setting: return .apps
        case .folder: return .folders
        case .file: return .files
        }
    }
}

/// Coarse media class of a path, by extension (cached).
enum FileKind: Sendable {
    case image, video, audio, pdf, other

    nonisolated(unsafe) private static var cache: [String: FileKind] = [:]
    private static let lock = NSLock()

    static func of(_ path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[ext] { return hit }
        let kind: FileKind
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) {
                kind = .pdf
            } else if type.conforms(to: .image) {
                kind = .image
            } else if type.conforms(to: .movie) || type.conforms(to: .video) {
                kind = .video
            } else if type.conforms(to: .audio) {
                kind = .audio
            } else {
                kind = .other
            }
        } else {
            kind = .other
        }
        cache[ext] = kind
        return kind
    }
}

/// Display strings: hostile names shown literally and safely, apps without ".app", grapheme-safe.
enum DisplayText {
    static func name(_ item: Item) -> String {
        var name = item.name
        if item.kind == .app, name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return sanitize(name)
    }

    /// Newlines shown as ⏎ and other control characters as U+FFFD; never interpreted.
    static func sanitize(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                out.append("⏎")
            } else if scalar.properties.generalCategory == .control {
                out.append("\u{FFFD}")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Candidate locations from full to shortest: `~/Documents/Finance/2025`, `~/…/Finance/2025`, `~/…/2025`.
    static func locations(_ item: Item) -> [String] {
        guard item.kind == .file || item.kind == .folder else { return [] }
        let parent = ((item.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let full = sanitize(parent)
        let parts = full.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return [full] }
        let head = full.hasPrefix("~") ? "~/…/" : "/…/"
        let two = head + parts.suffix(2).joined(separator: "/")
        let one = head + String(parts.last!)
        return [full, two, one]
    }

    /// "9,412", or "10,000+" above 9,999.
    static func count(_ n: Int) -> String {
        n > 9_999 ? "10,000+" : n.formatted(.number)
    }

    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Where inside the file: "p. 3", "line 42", "in image", "frame 01:23", "♪ 02:14", "by meaning".
    static func locator(_ result: SearchResult) -> String? {
        guard let match = result.match else { return result.source == .semantic ? "by meaning" : nil }
        let loc = match.location
        let fileKind = FileKind.of(result.item.path)
        var parts: [String] = []
        switch match.kind {
        case .text:
            if let page = loc.page { parts.append("p. \(page)") }
            if let line = loc.line { parts.append("line \(line)") }
        case .ocr:
            if let time = loc.time {
                parts.append("frame \(timecode(time))")
            } else if let page = loc.page {
                parts.append("p. \(page) · scan")
            } else {
                parts.append("in image")
            }
        case .transcript:
            parts.append("♪ \(timecode(loc.time ?? 0))")
        case .semantic:
            parts.append(loc.page.map { "≈ p. \($0)" } ?? "by meaning")
        case .image:
            if let time = loc.time {
                parts.append("≈ frame \(timecode(time))")
            } else {
                parts.append(fileKind == .video ? "≈ frame" : "≈ in image")
            }
        }
        if result.moreMatches > 0 {
            parts.append("+\(result.moreMatches) more")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken form for VoiceOver ("matched page 1: Acme Invoice total").
    static func spokenEvidence(_ result: SearchResult) -> String? {
        guard let match = result.match else { return nil }
        let where_ = locator(result) ?? ""
        return "matched \(where_): \(match.snippet)"
    }
}

/// Human kind label ("PDF document", "Folder", "Application"), cached per extension.
@MainActor
enum KindLabel {
    private static var byExtension: [String: String] = [:]

    static func text(for item: Item) -> String {
        switch item.kind {
        case .app: return "Application"
        case .setting: return "System Settings"
        case .folder: return "Folder"
        case .file:
            let ext = (item.name as NSString).pathExtension.lowercased()
            if let hit = byExtension[ext] { return hit }
            let label =
                ext.isEmpty
                ? "Document"
                : UTType(filenameExtension: ext)?.localizedDescription.map(capitalizeFirst) ?? "Document"
            byExtension[ext] = label
            return label
        }
    }

    private static func capitalizeFirst(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}
