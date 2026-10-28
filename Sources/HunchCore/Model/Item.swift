import Foundation

/// What kind of filesystem entry an `Item` is. Raw values are persisted — append only.
public enum ItemKind: UInt8, Sendable {
    case app = 0
    case folder = 1
    case file = 2
    /// A System Settings pane (see `SettingsPanes`).
    case setting = 3
}

/// One indexed entry (app, folder or file). `id` is stable for the lifetime of the catalog.
public struct Item: Sendable, Hashable {
    public var id: UInt32
    public var path: String
    public var name: String
    public var kind: ItemKind
    public var modified: Date

    public init(id: UInt32, path: String, name: String, kind: ItemKind, modified: Date) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.modified = modified
    }
}

/// Which retrievers found a result.
public enum MatchSource: Sendable {
    /// Name match (possibly with full-text evidence in `match`).
    case name
    /// Meaning match only (name vector or content chunk).
    case semantic
    /// Name match and meaning match.
    case both
    /// Found through the file's contents (full text), not its name.
    case content
}

/// Identity of one match: a file plus where inside it. Stable across emissions.
public struct ResultKey: Sendable, Hashable {
    public var item: UInt32
    public var location: ContentLocation?

    public init(item: UInt32, location: ContentLocation? = nil) {
        self.item = item
        self.location = location
    }
}

/// A ranked hit shown in the panel: one row per file, showing its best match.
public struct SearchResult: Sendable, Identifiable {
    public var item: Item
    public var score: Float
    public var source: MatchSource
    /// Best content evidence (nil for a pure name match or a name-vector match).
    public var match: ContentMatch?
    /// Further content matches in the same file beyond `match` ("N more matches").
    public var moreMatches: Int

    /// Row identity = the file. It never changes when later legs (semantic) refine the row, so selection holds.
    public var id: UInt32 { item.id }
    /// File + location of the shown match.
    public var key: ResultKey { ResultKey(item: item.id, location: match?.location) }

    public init(item: Item, score: Float, source: MatchSource, match: ContentMatch? = nil, moreMatches: Int = 0) {
        self.item = item
        self.score = score
        self.source = source
        self.match = match
        self.moreMatches = moreMatches
    }
}

/// A titled group of results (empty-query suggestions).
public struct SearchSection: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case favorites
        case recents
        case applications
    }

    public var kind: Kind
    public var title: String
    public var results: [SearchResult]

    public var id: Kind { kind }

    public init(kind: Kind, title: String, results: [SearchResult]) {
        self.kind = kind
        self.title = title
        self.results = results
    }
}
