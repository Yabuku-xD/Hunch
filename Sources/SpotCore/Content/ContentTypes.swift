import Foundation

/// One piece of searchable text pulled out of a file (owner: media).
public struct ExtractedChunk: Sendable, Hashable {
    /// `.text`, `.ocr` or `.transcript`.
    public var kind: ContentMatch.Kind
    public var text: String
    public var location: ContentLocation

    public init(kind: ContentMatch.Kind, text: String, location: ContentLocation = .whole) {
        self.kind = kind
        self.text = text
        self.location = location
    }
}

/// A vector for an image or a distinct video frame, already in the text query space.
public struct ExtractedImageVector: Sendable {
    public var location: ContentLocation
    /// OCR text of the frame, shown when the vector is a file's best match.
    public var caption: String?
    public var vector: [Float]

    public init(location: ContentLocation, caption: String?, vector: [Float]) {
        self.location = location
        self.caption = caption
        self.vector = vector
    }
}

/// Indexing tiers, cheapest first. Raw values are persisted in the queue — append only.
public enum ContentTier: Int, Sendable, CaseIterable, Comparable {
    /// Names (handled by the name index; never queued here).
    case names = 0
    /// Text-bearing documents: plain text, code, PDF text layers, office zips, rtf/doc.
    case documents = 1
    /// Images, iWork previews and scanned PDF pages (OCR + image vectors).
    case images = 2
    /// Video frames and audio transcripts.
    case media = 3

    public static func < (a: ContentTier, b: ContentTier) -> Bool { a.rawValue < b.rawValue }
}

/// Progress of one tier, for the status line.
public struct ContentTierProgress: Sendable, Equatable {
    public var tier: ContentTier
    /// Files done (including skipped/unreadable ones).
    public var done: Int
    /// Files known to this tier.
    public var total: Int

    public init(tier: ContentTier, done: Int, total: Int) {
        self.tier = tier
        self.done = done
        self.total = total
    }
}

/// What happened to one file. Raw values are persisted — append only.
public enum ExtractionStatus: Int, Sendable {
    case ok = 0
    /// Nothing to read in this format (binary, empty).
    case unsupported = 1
    /// Over a size cap (text 20 MB, image 100 MP, video 4 h): name only.
    case tooLarge = 2
    /// Corrupt, truncated or locked.
    case unreadable = 3
    /// Speech recognition isn't available (no installed locale); frames were still read.
    case speechUnavailable = 4
}

/// Everything extracted from one file in one tier.
public struct ExtractedContent: Sendable {
    public var status: ExtractionStatus
    public var chunks: [ExtractedChunk]
    public var images: [ExtractedImageVector]
    /// 1-based PDF pages without a text layer, to OCR in tier 2.
    public var scannedPages: [Int]
    /// Why a part was skipped (e.g. speech unavailable), for diagnostics.
    public var note: String?

    public init(status: ExtractionStatus = .ok, chunks: [ExtractedChunk] = [], images: [ExtractedImageVector] = [],
                scannedPages: [Int] = [], note: String? = nil) {
        self.status = status
        self.chunks = chunks
        self.images = images
        self.scannedPages = scannedPages
        self.note = note
    }

    static func failed(_ s: ExtractionStatus, _ note: String? = nil) -> ExtractedContent {
        ExtractedContent(status: s, note: note)
    }
}

/// Packed 8-bit RGB pixels (row-major, no padding), `Sendable` so images can cross actor boundaries.
public struct RGBImage: Sendable {
    public var width: Int
    public var height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// Identity of a file version (v3: `FileIdentity` + `FileStamp`): unchanged inode + size + mtime + dataless flag
/// means nothing to redo. ctime/doc id/clone id ride along but don't take part in equality (stored v2 rows lack them).
public struct FileFingerprint: Sendable, Hashable {
    public var identity: FileIdentity
    public var stamp: FileStamp

    public var inode: UInt64 {
        get { identity.fileID }
        set { identity.fileID = newValue }
    }
    public var size: Int64 {
        get { stamp.size }
        set { stamp.size = newValue }
    }
    /// Modification time in nanoseconds since 1970.
    public var mtime: Int64 {
        get { stamp.mtimeNs }
        set { stamp.mtimeNs = newValue }
    }
    public var isDataless: Bool { stamp.isDataless }

    public init(inode: UInt64, size: Int64, mtime: Int64, flags: UInt32 = 0, device: UInt64 = 0, ctime: Int64 = 0) {
        identity = FileIdentity(device: device, fileID: inode)
        stamp = FileStamp(size: size, mtimeNs: mtime, ctimeNs: ctime, flags: flags)
    }

    public init(identity: FileIdentity, stamp: FileStamp) {
        self.identity = identity
        self.stamp = stamp
    }

    public static func == (a: FileFingerprint, b: FileFingerprint) -> Bool {
        a.inode == b.inode && a.size == b.size && a.mtime == b.mtime && a.isDataless == b.isDataless
    }

    public func hash(into h: inout Hasher) {
        h.combine(inode)
        h.combine(size)
        h.combine(mtime)
    }

    /// `stat` of `path` (following nothing: packages report their directory), or nil when it's gone.
    public static func of(path: String) -> FileFingerprint? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var size = Int64(st.st_size)
        var mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            // iWork packages: the preview inside changes with the document.
            for sub in ["preview.jpg", "QuickLook/Thumbnail.jpg", "Index.zip"] {
                var s2 = stat()
                if stat(path + "/" + sub, &s2) == 0 {
                    size += Int64(s2.st_size)
                    mtime = max(mtime, Int64(s2.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(s2.st_mtimespec.tv_nsec))
                }
            }
        }
        return FileFingerprint(inode: UInt64(st.st_ino), size: size, mtime: mtime, flags: st.st_flags,
                               device: UInt64(UInt32(bitPattern: st.st_dev)),
                               ctime: Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec))
    }
}
