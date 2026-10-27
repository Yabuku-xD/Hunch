import Foundation

/// What the indexer is doing, for the status line.
public struct IndexStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Caught up; watching for changes.
        case idle
        /// Walking the roots (first launch, rebuild or a must-rescan event).
        case crawling
        /// Computing name vectors for new or changed items.
        case embedding
        /// Embedding held while the panel is visible.
        case paused
        /// No embedding model found (or it failed to load): name search only.
        case modelMissing
        /// Replaying the FSEvents journal since the last run.
        case catchingUp
        /// Stat-only verify scan (journal loss, root added, rules changed, user request).
        case verifying(VerifyReason)
    }

    public var phase: Phase
    /// Items in the catalog (searchable by name).
    public var items: Int
    /// Items whose name vector is current.
    public var embedded: Int
    /// Items that need a vector (embedded + still pending).
    public var total: Int
    /// Content progress per tier (T1–T3): files done / known.
    public var content: [ContentTierProgress] = []
    /// Dataless (cloud-only) files: searchable by name only (K2).
    public var cloudOnly: Int = 0
    /// Roots and top-level folders the process may not read (EPERM/EACCES, K21).
    public var unreadable: [String] = []
    /// Huge/cold files waiting for idle + AC power.
    public var deferred: Int = 0
    public var lastVerify: VerifyReport?

    public init(phase: Phase = .idle, items: Int = 0, embedded: Int = 0, total: Int = 0,
                content: [ContentTierProgress] = [], cloudOnly: Int = 0, unreadable: [String] = [],
                deferred: Int = 0, lastVerify: VerifyReport? = nil) {
        self.phase = phase
        self.items = items
        self.embedded = embedded
        self.total = total
        self.content = content
        self.cloudOnly = cloudOnly
        self.unreadable = unreadable
        self.deferred = deferred
        self.lastVerify = lastVerify
    }
}

/// User-chosen indexing scope, persisted in the catalog's `meta` table (key `settings.index`, JSON).
public struct IndexSettings: Sendable, Equatable, Codable {
    public var roots: [URL]
    /// Paths removed from the index (P17): range-deleted, never crawled.
    public var exclusions: [String]
    /// Read file contents (text, OCR, transcripts, content vectors). Names are always indexed.
    public var contentIndexing: Bool

    public init(roots: [URL], exclusions: [String] = [], contentIndexing: Bool = true) {
        self.roots = roots
        self.exclusions = exclusions
        self.contentIndexing = contentIndexing
    }

    /// Version of the crawl rules (skip names, package leaves). A mismatch with the stored value triggers
    /// `verify(.rulesChanged)`, never a rebuild.
    public static let rulesVersion = "3"

    /// Home plus the application folders.
    public static var `default`: IndexSettings { IndexSettings(roots: Crawler.defaultRoots) }

    static let metaKey = "settings.index"

    func encoded() -> String? {
        let stored = Stored(roots: roots.map(\.path), exclusions: exclusions, contentIndexing: contentIndexing)
        return (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ s: String?) -> IndexSettings? {
        guard let data = s?.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.roots.isEmpty else { return nil }
        return IndexSettings(roots: stored.roots.map { URL(fileURLWithPath: PathKey.canonical($0), isDirectory: true) },
                             exclusions: (stored.exclusions ?? []).map(PathKey.canonical),
                             contentIndexing: stored.contentIndexing ?? true)
    }

    /// v2 stored only `roots`; the new fields are optional so old settings decode unchanged.
    private struct Stored: Codable {
        var roots: [String]
        var exclusions: [String]?
        var contentIndexing: Bool?
    }
}

/// Frecency with exponential decay: each open adds 1, and the total halves every `halfLife` (7 days).
public struct Frecency: Sendable, Equatable {
    public static let halfLife: TimeInterval = 7 * 86_400

    /// Score as of `at`.
    public var score: Double
    public var at: Date

    public init(score: Double = 0, at: Date = .distantPast) {
        self.score = score
        self.at = at
    }

    public func value(at date: Date) -> Double {
        let dt = max(0, date.timeIntervalSince(at))
        return score * exp2(-dt / Self.halfLife)
    }

    /// One more open at `date`.
    public func adding(at date: Date) -> Frecency {
        date >= at ? Frecency(score: value(at: date) + 1, at: date)
                   : Frecency(score: score + exp2(-at.timeIntervalSince(date) / Self.halfLife), at: at)
    }
}
