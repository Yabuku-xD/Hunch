import Foundation

/// What the user opened after typing a query: folded query → item id → number of opens. Typing that query again, or
/// one that extends or shortens it, ranks those items higher (`NameIndex`). Bounded: at most `capacity` queries,
/// the least recently used one is dropped first.
public struct QueryPicks: Codable, Sendable, Equatable {
    public static let capacity = 256
    /// Largest raw-score boost a pick can add (one tier is 200 points apart, see `NameIndex`).
    public static let maxBoost: Float = 60

    private var picks: [String: [UInt32: Int]] = [:]
    /// Queries, least recently used first.
    private var order: [String] = []

    public init() {}

    public var count: Int { picks.count }

    public mutating func record(_ key: String, _ id: UInt32) {
        guard !key.isEmpty else { return }
        picks[key, default: [:]][id, default: 0] += 1
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        while order.count > Self.capacity { picks.removeValue(forKey: order.removeFirst()) }
    }

    /// Raw-score boost per item for `key`: full weight for the same query, half for a query that extends or
    /// shortens it ("saf" after picking Safari for "safari").
    public func boosts(_ key: String) -> [UInt32: Float] {
        guard !key.isEmpty, !picks.isEmpty else { return [:] }
        var out: [UInt32: Float] = [:]
        for (k, ids) in picks {
            let weight: Float = k == key ? 1 : (k.hasPrefix(key) || key.hasPrefix(k)) ? 0.5 : 0
            guard weight > 0 else { continue }
            for (id, n) in ids {
                out[id] = max(out[id] ?? 0, weight * min(Self.maxBoost, 30 * log2(1 + Float(n))))
            }
        }
        return out
    }
}
