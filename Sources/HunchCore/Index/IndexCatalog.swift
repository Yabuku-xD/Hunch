import Foundation

/// What the indexer needs from the catalog (owner: indexer). The engine's SQLite `Catalog` can adopt
/// this via an extension (done by integrate); `MemoryCatalog` is the in-process reference implementation.
///
/// Persistence contract for resumability: ids are stable per path, the pending-embedding set and
/// `meta` survive relaunch.
public protocol IndexCatalog: Sendable {
    func allItems() async -> [Item]
    /// Inserts/updates by path (ids assigned on first sight). New or changed (`modified` differs)
    /// items become pending for embedding. Returns the stored items.
    func upsert(_ entries: [CrawlEntry]) async -> [Item]
    /// Removes each path and everything below it. Returns removed ids.
    func remove(paths: [String]) async -> [UInt32]
    /// Reconciles everything at or below `roots` with `entries`: upserts entries, removes the rest.
    func replace(under roots: [String], with entries: [CrawlEntry]) async -> (upserted: [Item], removed: [UInt32])
    /// Up to `limit` items still waiting for a vector (stable order; not removed until marked).
    func pendingEmbedding(limit: Int) async -> [Item]
    func markEmbedded(_ ids: [UInt32]) async
    func meta(_ key: String) async -> String?
    func setMeta(_ key: String, _ value: String?) async

    // MARK: v3 (identity-keyed, incremental)

    /// Identity-aware upsert: unchanged entries write nothing (`change == nil`), moves keep their id.
    func upsertEntries(_ entries: [CrawlEntry]) async -> [CatalogUpsert]
    /// Reconciles `roots` with `entries` (a complete listing of them minus `excluding` subtrees, which belong to
    /// other roots): identity-aware upserts, then range-scoped removal of what is gone.
    func reconcile(
        under roots: [String], with entries: [CrawlEntry], excluding: [String]
    ) async
        -> (upserts: [CatalogUpsert], removed: [UInt32])
    /// Exact-input hash of the item's current name vector.
    func nameVectorHash(_ id: UInt32) async -> Data?
    func markEmbedded(_ pairs: [(id: UInt32, hash: Data)]) async
    /// `items` rows written so far (bench: "rows written").
    func rowsWritten() async -> Int
}

extension IndexCatalog {
    public func reconcile(
        under roots: [String], with entries: [CrawlEntry]
    ) async
        -> (upserts: [CatalogUpsert], removed: [UInt32])
    {
        await reconcile(under: roots, with: entries, excluding: [])
    }

    static func isAtOrBelow(_ path: String, anyOf set: [String]) -> Bool {
        set.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// In-memory `IndexCatalog`.
public actor MemoryCatalog: IndexCatalog {
    private var byPath: [String: Item] = [:]
    private var pathByID: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var pendingSet: Set<UInt32> = []
    private var pendingQueue: [UInt32] = []
    private var pendingHead = 0
    private var metadata: [String: String] = [:]
    private var byIdentity: [FileIdentity: UInt32] = [:]
    private var stamps: [UInt32: (FileIdentity?, FileStamp?)] = [:]
    private var vecHash: [UInt32: Data] = [:]
    private var written = 0

    public init() {}

    private static func key(_ i: FileIdentity) -> FileIdentity { FileIdentity(device: i.device, fileID: i.fileID) }

    public func upsertEntries(_ entries: [CrawlEntry]) -> [CatalogUpsert] {
        entries.map { e in
            if var old = byPath[e.path] {
                let (oi, os) = stamps[old.id] ?? (nil, nil)
                let same =
                    old.name == e.name && old.kind == e.kind
                    && (e.stamp != nil && os != nil
                        ? (os == e.stamp && oi.map(Self.key) == e.identity.map(Self.key))
                        : old.modified == e.modified)
                if same { return CatalogUpsert(item: old, change: nil) }
                old.name = e.name
                old.kind = e.kind
                old.modified = e.modified
                byPath[e.path] = old
                record(old.id, e)
                markPending(old.id)
                written += 1
                return CatalogUpsert(item: old, change: .metadata)
            }
            if let ident = e.identity, let id = byIdentity[Self.key(ident)], let oldPath = pathByID[id],
                var old = byPath[oldPath], !Catalog.stillThere(oldPath, ident)
            {
                byPath[oldPath] = nil
                old.path = e.path
                old.name = e.name
                old.kind = e.kind
                old.modified = e.modified
                byPath[e.path] = old
                pathByID[id] = e.path
                record(id, e)
                markPending(id)
                written += 1
                return CatalogUpsert(item: old, change: .renamed(from: oldPath))
            }
            let item = upsert([e])[0]
            record(item.id, e)
            written += 1
            return CatalogUpsert(item: item, change: .added)
        }
    }

    private func record(_ id: UInt32, _ e: CrawlEntry) {
        stamps[id] = (e.identity, e.stamp)
        if let i = e.identity { byIdentity[Self.key(i)] = id }
    }

    public func reconcile(
        under roots: [String], with entries: [CrawlEntry], excluding: [String]
    )
        -> (upserts: [CatalogUpsert], removed: [UInt32])
    {
        let ups = upsertEntries(entries)
        let keep = Set(entries.map(\.path))
        var removed: [UInt32] = []
        for (path, item) in byPath
        where !keep.contains(path) && Self.isAtOrBelow(path, anyOf: roots)
            && !Self.isAtOrBelow(path, anyOf: excluding)
        {
            drop(item)
            removed.append(item.id)
        }
        written += removed.count
        return (ups, removed)
    }

    public func nameVectorHash(_ id: UInt32) -> Data? { vecHash[id] }

    public func markEmbedded(_ pairs: [(id: UInt32, hash: Data)]) {
        for p in pairs {
            pendingSet.remove(p.id)
            vecHash[p.id] = p.hash
        }
    }

    public func rowsWritten() -> Int { written }

    public var count: Int { byPath.count }
    public var pendingCount: Int { pendingSet.count }

    public func item(_ id: UInt32) -> Item? { pathByID[id].flatMap { byPath[$0] } }
    public func item(path: String) -> Item? { byPath[path] }

    public func allItems() -> [Item] { Array(byPath.values) }

    public func upsert(_ entries: [CrawlEntry]) -> [Item] {
        entries.map { e in
            if var old = byPath[e.path] {
                let changed = old.modified != e.modified || old.kind != e.kind || old.name != e.name
                old.name = e.name
                old.kind = e.kind
                old.modified = e.modified
                byPath[e.path] = old
                if changed { markPending(old.id) }
                return old
            }
            let item = Item(id: nextID, path: e.path, name: e.name, kind: e.kind, modified: e.modified)
            nextID += 1
            byPath[e.path] = item
            pathByID[item.id] = e.path
            markPending(item.id)
            return item
        }
    }

    public func remove(paths: [String]) -> [UInt32] {
        var removed: [UInt32] = []
        var subtrees: [String] = []
        for p in paths {
            if let item = byPath[p] {
                drop(item)
                removed.append(item.id)
                if item.kind == .folder { subtrees.append(p + "/") }
            } else {
                subtrees.append(p + "/")  // unknown path: may have been a folder
            }
        }
        if !subtrees.isEmpty {
            for (path, item) in byPath where subtrees.contains(where: { path.hasPrefix($0) }) {
                drop(item)
                removed.append(item.id)
            }
        }
        return removed
    }

    public func replace(under roots: [String], with entries: [CrawlEntry]) -> (upserted: [Item], removed: [UInt32]) {
        let keep = Set(entries.map(\.path))
        let upserted = upsert(entries)
        var removed: [UInt32] = []
        for (path, item) in byPath
        where !keep.contains(path)
            && roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
        {
            drop(item)
            removed.append(item.id)
        }
        return (upserted, removed)
    }

    public func pendingEmbedding(limit: Int) -> [Item] {
        while pendingHead < pendingQueue.count && !pendingSet.contains(pendingQueue[pendingHead]) {
            pendingHead += 1
        }
        if pendingHead > 4096 && pendingHead * 2 > pendingQueue.count {
            pendingQueue.removeFirst(pendingHead)
            pendingHead = 0
        }
        var out: [Item] = []
        var seen: Set<UInt32> = []
        var i = pendingHead
        while i < pendingQueue.count && out.count < limit {
            let id = pendingQueue[i]
            if pendingSet.contains(id), seen.insert(id).inserted, let item = item(id) { out.append(item) }
            i += 1
        }
        return out
    }

    public func markEmbedded(_ ids: [UInt32]) {
        for id in ids { pendingSet.remove(id) }
    }

    public func meta(_ key: String) -> String? { metadata[key] }

    public func setMeta(_ key: String, _ value: String?) { metadata[key] = value }

    private func markPending(_ id: UInt32) {
        if pendingSet.insert(id).inserted { pendingQueue.append(id) }
    }

    private func drop(_ item: Item) {
        byPath[item.path] = nil
        pathByID[item.id] = nil
        pendingSet.remove(item.id)
        if let i = stamps.removeValue(forKey: item.id)?.0, byIdentity[Self.key(i)] == item.id {
            byIdentity[Self.key(i)] = nil
        }
        vecHash[item.id] = nil
    }
}
