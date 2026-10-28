import Foundation

/// Vector key: `item id << 24 | chunk index`. Index 0 is the item's name document; content chunks use 1...maxIndex.
public typealias ChunkID = UInt64

public enum Chunk {
    public static let indexBits: UInt64 = 24
    public static let maxIndex: UInt32 = (1 << 24) - 1

    public static func id(item: UInt32, index: UInt32 = 0) -> ChunkID {
        UInt64(item) << indexBits | UInt64(index & maxIndex)
    }

    public static func item(_ id: ChunkID) -> UInt32 { UInt32(truncatingIfNeeded: id >> indexBits) }
    public static func index(_ id: ChunkID) -> UInt32 { UInt32(truncatingIfNeeded: id & UInt64(maxIndex)) }
    /// Every chunk id of `item`, for range scans.
    public static func range(item: UInt32) -> ClosedRange<ChunkID> {
        id(item: item, index: 0)...id(item: item, index: maxIndex)
    }
}

/// A rectangle inside a page, image or video frame, normalized to 0...1 with the origin at the top left.
public struct ContentRegion: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Where inside a file a match sits. Every field is optional; an all-nil location means "the whole file".
public struct ContentLocation: Sendable, Hashable, Codable {
    /// 1-based page (PDF, presentation slide).
    public var page: Int?
    /// 1-based line (plain text, source code).
    public var line: Int?
    /// Seconds from the start (audio/video).
    public var time: Double?
    /// Area inside the page or frame (OCR text, image region).
    public var region: ContentRegion?

    public init(page: Int? = nil, line: Int? = nil, time: Double? = nil, region: ContentRegion? = nil) {
        self.page = page
        self.line = line
        self.time = time
        self.region = region
    }

    public static let whole = ContentLocation()
}

/// The best evidence for why a file matched, shown under its row.
public struct ContentMatch: Sendable, Hashable {
    /// Raw values are persisted in the chunk table — append only.
    public enum Kind: UInt8, Sendable, Hashable, Codable {
        /// Text inside a document.
        case text = 0
        /// Text recognized in an image or video frame.
        case ocr = 1
        /// Speech recognized in audio/video.
        case transcript = 2
        /// Meaning match against a text chunk.
        case semantic = 3
        /// Meaning match against an image or video frame.
        case image = 4
    }

    public var kind: Kind
    public var snippet: String
    /// Ranges to emphasize, as UTF-16 offsets into `snippet` (NSRange-compatible).
    public var highlights: [Range<Int>]
    public var location: ContentLocation

    public init(kind: Kind, snippet: String, highlights: [Range<Int>] = [], location: ContentLocation = .whole) {
        self.kind = kind
        self.snippet = snippet
        self.highlights = highlights
        self.location = location
    }
}

/// One full-text hit (owner: media implements `FullTextIndexing`).
public struct FullTextHit: Sendable, Hashable {
    public var item: UInt32
    /// `.text`, `.ocr` or `.transcript`.
    public var kind: ContentMatch.Kind
    public var location: ContentLocation
    public var snippet: String
    /// UTF-16 offsets into `snippet`.
    public var highlights: [Range<Int>]
    /// Relevance, higher is better (i.e. `-bm25()` from FTS5). Only the order is used for fusion.
    public var bm25: Double
    /// The query occurs in the text as a contiguous phrase (case/diacritic-insensitive). Files with such a hit
    /// always rank above semantic-only files.
    public var isExactPhrase: Bool

    public init(
        item: UInt32, kind: ContentMatch.Kind = .text, location: ContentLocation = .whole, snippet: String,
        highlights: [Range<Int>] = [], bm25: Double, isExactPhrase: Bool
    ) {
        self.item = item
        self.kind = kind
        self.location = location
        self.snippet = snippet
        self.highlights = highlights
        self.bm25 = bm25
        self.isExactPhrase = isExactPhrase
    }
}

/// What a content vector is (row of the chunk table, keyed by `ChunkID`).
public struct ChunkInfo: Sendable, Hashable {
    public var id: ChunkID
    /// `.semantic` for text chunks, `.image` for images / video frames.
    public var kind: ContentMatch.Kind
    public var location: ContentLocation
    /// UTF-16 offset of the chunk in the file's extracted text, when it is text.
    public var textOffset: Int?
    /// Short text to show when this chunk is a file's best match.
    public var snippet: String?

    public var item: UInt32 { Chunk.item(id) }

    public init(
        id: ChunkID, kind: ContentMatch.Kind, location: ContentLocation = .whole, textOffset: Int? = nil,
        snippet: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.location = location
        self.textOffset = textOffset
        self.snippet = snippet
    }
}

public struct ContentPipelineStatus: Sendable, Equatable {
    public var pending: Int
    public var processed: Int
    public var isPaused: Bool
    /// Dataless (cloud-only) files known to the pipeline: searchable by name only.
    public var cloudOnly: Int

    public init(pending: Int = 0, processed: Int = 0, isPaused: Bool = false, cloudOnly: Int = 0) {
        self.pending = pending
        self.processed = processed
        self.isPaused = isPaused
        self.cloudOnly = cloudOnly
    }
}

/// Placeholder until the media team's pipeline is attached: accepts work and does nothing.
public struct NoContentPipeline: ContentPipeline {
    public init() {}
    public func enqueue(_ items: [Item]) async {}
    public func remove(_ ids: [UInt32]) async {}
    public func pause() async {}
    public func resume() async {}
    public var status: ContentPipelineStatus { get async { ContentPipelineStatus() } }
}

/// Placeholder full-text index: never matches.
public struct EmptyFullTextIndex: FullTextIndexing {
    public init() {}
    public func search(_ q: String, limit: Int) -> [FullTextHit] { [] }
}
