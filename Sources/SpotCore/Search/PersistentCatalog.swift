import Foundation
import os
import Synchronization

/// `IndexCatalog` over the engine's SQLite `Catalog` (owner: integrate), so a relaunch resumes instead of re-crawling:
/// ids are stable per path, the pending-embedding set is the `embedded = 0` rows and meta lives in the `meta` table.
/// SQLite failures are logged and treated as no-ops; the next crawl or event replay reconciles.
public final class PersistentCatalog: IndexCatalog {
    public let store: Catalog
    private static let log = Logger(subsystem: "dev.betterspotlight", category: "catalog")

    public init(_ store: Catalog) {
        self.store = store
    }

    public func allItems() async -> [Item] {
        Array(store.items)  // in-memory mirror, no SQL scan
    }

    public func upsert(_ entries: [CrawlEntry]) async -> [Item] {
        upsertNow(entries)
    }

    /// Range delete per path (K6): no full-table read in any event path.
    public func remove(paths: [String]) async -> [UInt32] {
        guard !paths.isEmpty else { return [] }
        return attempt("remove") { try store.deleteSubtree(paths) } ?? []
    }

    public func replace(under roots: [String], with entries: [CrawlEntry]) async -> (upserted: [Item], removed: [UInt32]) {
        let r = await reconcile(under: roots, with: entries, excluding: [])
        return (r.upserts.map(\.item), r.removed)
    }

    public func upsertEntries(_ entries: [CrawlEntry]) async -> [CatalogUpsert] {
        attempt("upsert") { try store.upsertEntries(entries) } ?? []
    }

    public func reconcile(under roots: [String], with entries: [CrawlEntry], excluding: [String]) async
        -> (upserts: [CatalogUpsert], removed: [UInt32]) {
        let ups = attempt("upsert") { try store.upsertEntries(entries) } ?? []
        let keep = Set(entries.map(\.path))
        var stale: [String] = []
        for root in roots {
            for item in (attempt("under") { try store.items(under: root) } ?? [])
            where !keep.contains(item.path) && !excluding.contains(where: { Crawler.isInside(item.path, $0) }) {
                stale.append(item.path)
            }
        }
        let removed = stale.isEmpty ? [] : (attempt("remove") { try store.remove(paths: stale) } ?? [])
        return (ups, removed)
    }

    public func nameVectorHash(_ id: UInt32) async -> Data? {
        attempt("nameVectorHash") { try store.nameVectorHash(id) } ?? nil
    }

    public func markEmbedded(_ pairs: [(id: UInt32, hash: Data)]) async {
        _ = attempt("markEmbedded") { try store.markEmbedded(pairs) }
    }

    public func rowsWritten() async -> Int { store.itemRowsWritten.load(ordering: .relaxed) }

    public func pendingEmbedding(limit: Int) async -> [Item] {
        attempt("pending") { try store.pendingEmbedding(limit: limit) } ?? []
    }

    public func markEmbedded(_ ids: [UInt32]) async {
        _ = attempt("markEmbedded") { try store.markEmbedded(ids) }
    }

    public func meta(_ key: String) async -> String? {
        attempt("meta") { try store.meta(key) } ?? nil
    }

    public func setMeta(_ key: String, _ value: String?) async {
        _ = attempt("setMeta") { try store.setMeta(key, value) }
    }

    // MARK: Helpers

    private func upsertNow(_ entries: [CrawlEntry]) -> [Item] {
        guard !entries.isEmpty else { return [] }
        return (attempt("upsert") { try store.upsertEntries(entries) } ?? []).map(\.item)
    }

    /// True when `path` or one of its ancestors is in `set`. Walks ancestors, so the cost is O(depth), not O(|set|).
    static func isAtOrBelow(_ path: String, anyOf set: Set<String>) -> Bool {
        var p = Substring(path)
        while !p.isEmpty {
            if set.contains(String(p)) { return true }
            guard let slash = p.lastIndex(of: "/") else { return false }
            p = p[..<slash]
        }
        return false
    }

    private func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            Self.log.error("catalog \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
