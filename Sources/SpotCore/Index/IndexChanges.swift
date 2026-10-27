import Foundation

/// One catalog change, for the app's stale-result refresh (P8) and the status line (v3 plan §B.1).
public struct IndexChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case added
        case renamed(from: String)
        case metadata
        case contentUpdated(ContentTier)
        case removed
    }

    public var itemID: Int64
    public var path: String
    public var kind: Kind

    public init(itemID: Int64, path: String, kind: Kind) {
        self.itemID = itemID
        self.path = path
        self.kind = kind
    }
}

public struct IndexChangeBatch: Sendable {
    public var generation: UInt64
    public var changes: [IndexChange]

    public init(generation: UInt64, changes: [IndexChange]) {
        self.generation = generation
        self.changes = changes
    }
}

/// Per-volume FSEvents journal position (I3).
public struct VolumeCursor: Sendable, Codable, Hashable {
    public var uuid: String
    public var device: UInt64
    public var mount: String
    public var lastEventID: UInt64
    public var online: Bool
    public var verifiedAt: Date?

    public init(uuid: String, device: UInt64, mount: String, lastEventID: UInt64, online: Bool = true,
                verifiedAt: Date? = nil) {
        self.uuid = uuid
        self.device = device
        self.mount = mount
        self.lastEventID = lastEventID
        self.online = online
        self.verifiedAt = verifiedAt
    }
}

/// Why a stat-only verify scan ran.
public enum VerifyReason: Sendable, Hashable {
    case droppedEvents, idsWrapped, volumeChanged, rootAdded, rulesChanged, userRequested, migration
}

/// What a verify scan found and wrote. An unchanged tree reports `rowsWritten == 0`.
public struct VerifyReport: Sendable, Equatable {
    public var scanned, added, changed, moved, removed, rowsWritten: Int
    public var wall: Duration

    public init(scanned: Int = 0, added: Int = 0, changed: Int = 0, moved: Int = 0, removed: Int = 0,
                rowsWritten: Int = 0, wall: Duration = .zero) {
        self.scanned = scanned
        self.added = added
        self.changed = changed
        self.moved = moved
        self.removed = removed
        self.rowsWritten = rowsWritten
        self.wall = wall
    }
}

/// How urgently `SearchBackend.indexNow` should read a file.
public enum ContentPriority: Int, Sendable {
    case background, normal, userInitiated
}

/// Result of a catalog upsert for one entry: the stored item and what changed (nil = nothing, no row written).
public struct CatalogUpsert: Sendable {
    public var item: Item
    public var change: IndexChange.Kind?

    public init(item: Item, change: IndexChange.Kind?) {
        self.item = item
        self.change = change
    }
}
