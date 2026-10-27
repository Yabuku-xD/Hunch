import Foundation
import Synchronization

/// In-memory fuzzy name matcher (owner: indexer).
///
/// Storage is one contiguous buffer of folded (lowercased, diacritic-stripped) UTF-8 names plus
/// offsets and parallel arrays. Readers copy the immutable `Storage` value under the mutex (a few
/// refcount bumps) and scan without holding the lock; writers mutate copy-on-write.
///
/// Raw score tiers (then divided by `NameIndex.scoreScale`, so scores land roughly in 0...1):
/// exact 1000 · exact-stem 950 · prefix 800+ · word-boundary prefix 600+ · acronym 450+ ·
/// fuzzy subsequence 10–300 (gap penalty). Boosts (≤ 180 total, below the 200-point tier gap):
/// app +80, frecency of opens up to +60 (half-life 7 days, see `Frecency`), modification recency up to +40.
public final class NameIndex: NameIndexing, Sendable {
    public static let scoreScale: Float = 1300

    struct Storage: Sendable {
        var bytes: [UInt8] = []
        /// Per byte: bit0 = word start.
        var flags: [UInt8] = []
        /// Byte offsets; `starts[i] ..< starts[i + 1]` is slot `i`.
        var starts: [UInt32] = [0]
        /// Length of the name without its extension (== length when there is none).
        var stemLens: [UInt32] = []
        var masks: [UInt64] = []
        var ids: [UInt32] = []
        var kinds: [UInt8] = []
        var alive: [Bool] = []
        /// Frecency score as of `frecencyAt` (timeIntervalSinceReferenceDate).
        var frecency: [Float] = []
        var frecencyAt: [Double] = []
        /// Modification date as timeIntervalSinceReferenceDate.
        var lastUsed: [Double] = []
        var slot: [UInt32: Int32] = [:]
        /// K7: slot of the item a row belongs to (== its own index for the primary name row; alias rows point at it).
        var primary: [Int32] = []
        /// Alias rows per item id.
        var aliasSlots: [UInt32: [Int32]] = [:]
        var dead = 0

        var liveCount: Int { slot.count }

        mutating func append(_ item: Item, frecency fr: (Float, Double) = (0, 0)) {
            let (b, f) = NameIndex.fold(item.name)
            let index = Int32(ids.count)
            bytes.append(contentsOf: b)
            flags.append(contentsOf: f)
            starts.append(UInt32(bytes.count))
            var stem = b.count
            if item.kind != .folder, let dot = b.lastIndex(of: UInt8(ascii: ".")), dot > 0 {
                stem = dot
            }
            stemLens.append(UInt32(stem))
            masks.append(NameIndex.mask(b))
            ids.append(item.id)
            kinds.append(item.kind.rawValue)
            alive.append(true)
            frecency.append(fr.0)
            frecencyAt.append(fr.1)
            lastUsed.append(item.modified.timeIntervalSinceReferenceDate)
            primary.append(index)
            slot[item.id] = index
        }

        /// Appends `keys` as extra rows of the item just appended with `append(_:)`.
        mutating func appendAliases(_ keys: [String], of item: Item) {
            guard !keys.isEmpty, let p = slot[item.id] else { return }
            for key in keys {
                let (b, f) = NameIndex.fold(key)
                guard !b.isEmpty else { continue }
                let index = Int32(ids.count)
                bytes.append(contentsOf: b)
                flags.append(contentsOf: f)
                starts.append(UInt32(bytes.count))
                stemLens.append(UInt32(b.count))
                masks.append(NameIndex.mask(b))
                ids.append(item.id)
                kinds.append(item.kind.rawValue)
                alive.append(true)
                frecency.append(0)
                frecencyAt.append(0)
                lastUsed.append(0)
                primary.append(p)
                aliasSlots[item.id, default: []].append(index)
            }
        }

        mutating func kill(_ id: UInt32) -> (Float, Double)? {
            guard let s = slot.removeValue(forKey: id) else { return nil }
            let i = Int(s)
            alive[i] = false
            dead += 1
            for a in aliasSlots.removeValue(forKey: id) ?? [] {
                alive[Int(a)] = false
                dead += 1
            }
            return (frecency[i], frecencyAt[i])
        }

        func frecencyPair(_ i: Int) -> (Float, Double) { (frecency[i], frecencyAt[i]) }

        func compacted() -> Storage {
            var out = Storage()
            out.bytes.reserveCapacity(bytes.count)
            var moved: [Int32: Int32] = [:]
            for i in ids.indices where alive[i] {
                let s = Int(starts[i]), e = Int(starts[i + 1])
                let index = Int32(out.ids.count)
                let isPrimary = primary[i] == Int32(i)
                if isPrimary { moved[Int32(i)] = index }
                let p = isPrimary ? index : (moved[primary[i]] ?? index)
                out.primary.append(p)
                if !isPrimary { out.aliasSlots[ids[i], default: []].append(index) }
                out.bytes.append(contentsOf: bytes[s..<e])
                out.flags.append(contentsOf: flags[s..<e])
                out.starts.append(UInt32(out.bytes.count))
                out.stemLens.append(stemLens[i])
                out.masks.append(masks[i])
                out.ids.append(ids[i])
                out.kinds.append(kinds[i])
                out.alive.append(true)
                out.frecency.append(frecency[i])
                out.frecencyAt.append(frecencyAt[i])
                out.lastUsed.append(lastUsed[i])
                if isPrimary { out.slot[ids[i]] = index }
            }
            return out
        }
    }

    private let state = Mutex<Storage>(Storage())
    /// K7 alias keys per item (app display/localized names, pinyin). Called outside the lock, at index time only.
    private let aliases: @Sendable (Item) -> [String]

    public init(aliases: @escaping @Sendable (Item) -> [String] = { AppNames.keys(for: $0) }) {
        self.aliases = aliases
    }

    public convenience init(items: [Item]) {
        self.init()
        replaceAll(items)
    }

    func currentStorage() -> Storage { state.withLock { $0 } }
    func replaceStorage(_ s: Storage) { state.withLock { $0 = s } }

    /// Number of live entries.
    public var count: Int { state.withLock { $0.liveCount } }

    /// Rebuilds the index from scratch (frecency of surviving ids is kept).
    public func replaceAll(_ items: some Sequence<Item>) {
        let old = state.withLock { $0 }
        var s = Storage()
        let n = items.underestimatedCount
        s.bytes.reserveCapacity(n * 24)
        s.flags.reserveCapacity(n * 24)
        s.starts.reserveCapacity(n + 1)
        s.stemLens.reserveCapacity(n)
        s.masks.reserveCapacity(n)
        s.ids.reserveCapacity(n)
        s.kinds.reserveCapacity(n)
        s.alive.reserveCapacity(n)
        s.frecency.reserveCapacity(n)
        s.frecencyAt.reserveCapacity(n)
        s.lastUsed.reserveCapacity(n)
        s.slot.reserveCapacity(n)
        s.primary.reserveCapacity(n)
        for item in items {
            if let prev = old.slot[item.id] {
                s.append(item, frecency: old.frecencyPair(Int(prev)))
            } else {
                s.append(item)
            }
            s.appendAliases(aliases(item), of: item)
        }
        state.withLock { $0 = s }
    }

    /// Inserts or replaces items by id.
    public func upsert(_ items: [Item]) {
        guard !items.isEmpty else { return }
        let keys = items.map(aliases)
        state.withLock { s in
            for (item, k) in zip(items, keys) {
                let prev = s.kill(item.id)
                s.append(item, frecency: prev ?? (0, 0))
                s.appendAliases(k, of: item)
            }
            Self.maybeCompact(&s)
        }
    }

    public func remove(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        state.withLock { s in
            for id in ids { _ = s.kill(id) }
            Self.maybeCompact(&s)
        }
    }

    /// Records that the user opened `id` (adds 1 to its decaying frecency).
    public func recordOpen(_ id: UInt32, at date: Date = .now) {
        state.withLock { s in
            guard let i = s.slot[id].map(Int.init) else { return }
            let f = Frecency(score: Double(s.frecency[i]), at: Date(timeIntervalSinceReferenceDate: s.frecencyAt[i]))
                .adding(at: date)
            s.frecency[i] = Float(f.score)
            s.frecencyAt[i] = f.at.timeIntervalSinceReferenceDate
        }
    }

    /// Restores a persisted frecency (launch).
    public func setFrecency(_ id: UInt32, _ f: Frecency) {
        state.withLock { s in
            guard let i = s.slot[id].map(Int.init) else { return }
            s.frecency[i] = Float(f.score)
            s.frecencyAt[i] = f.at.timeIntervalSinceReferenceDate
        }
    }

    /// Current frecency of `id` (0 when never opened).
    public func frecency(_ id: UInt32, at date: Date = .now) -> Double {
        state.withLock { s in
            guard let i = s.slot[id].map(Int.init) else { return 0 }
            return Frecency(score: Double(s.frecency[i]), at: Date(timeIntervalSinceReferenceDate: s.frecencyAt[i]))
                .value(at: date)
        }
    }

    private static func maybeCompact(_ s: inout Storage) {
        if s.dead > 1024 && s.dead * 4 > s.ids.count { s = s.compacted() }
    }

    // MARK: Search

    public func search(_ q: String, limit: Int) -> [(id: UInt32, score: Float)] {
        guard limit > 0 else { return [] }
        let query = Self.fold(q.trimmingCharacters(in: .whitespacesAndNewlines)).bytes
        guard !query.isEmpty else { return [] }
        let s = state.withLock { $0 }
        let now = Date.now.timeIntervalSinceReferenceDate
        return Self.scan(s, query: query, limit: limit, now: now)
    }

    private static func scan(_ s: Storage, query: [UInt8], limit: Int, now: Double) -> [(id: UInt32, score: Float)] {
        let qmask = mask(query)
        let qn = query.count
        // Alias rows share their item's id: collect a little more, then keep each id's best row.
        var top = TopK(limit: limit + (s.aliasSlots.isEmpty ? 0 : 8))

        s.bytes.withUnsafeBufferPointer { bytes in
            s.flags.withUnsafeBufferPointer { flags in
                s.starts.withUnsafeBufferPointer { starts in
                    s.masks.withUnsafeBufferPointer { masks in
                        s.alive.withUnsafeBufferPointer { alive in
                            query.withUnsafeBufferPointer { q in
                                for i in 0..<masks.count {
                                    guard alive[i], masks[i] & qmask == qmask else { continue }
                                    let start = Int(starts[i])
                                    let n = Int(starts[i + 1]) - start
                                    guard n >= qn else { continue }
                                    guard
                                        let raw = tierScore(
                                            name: UnsafeBufferPointer(rebasing: bytes[start..<(start + n)]),
                                            flags: UnsafeBufferPointer(rebasing: flags[start..<(start + n)]),
                                            stemLen: Int(s.stemLens[i]), q: q)
                                    else { continue }
                                    var score = raw - 0.1 * Float(n)
                                    if s.kinds[i] == ItemKind.app.rawValue { score += 80 }
                                    let p = Int(s.primary[i])
                                    let f = s.frecency[p]
                                    if f > 0 {
                                        let decayed =
                                            Double(f) * exp2(-max(0, now - s.frecencyAt[p]) / Frecency.halfLife)
                                        score += min(60, 30 * Float(log2(1 + decayed)))
                                    }
                                    let ageDays = max(0, now - s.lastUsed[p]) / 86_400
                                    score += Float(40 * exp(-ageDays / 14))
                                    top.offer(score, i)
                                }
                            }
                        }
                    }
                }
            }
        }
        var seen = Set<UInt32>()
        var out: [(id: UInt32, score: Float)] = []
        for hit in top.sorted() where out.count < limit && seen.insert(s.ids[hit.slot]).inserted {
            out.append((s.ids[hit.slot], hit.score / scoreScale))
        }
        return out
    }

    /// Returns the tier score for one name, or nil if the query does not match at all.
    @inline(__always)
    static func tierScore(
        name: UnsafeBufferPointer<UInt8>, flags: UnsafeBufferPointer<UInt8>,
        stemLen: Int, q: UnsafeBufferPointer<UInt8>
    ) -> Float? {
        let n = name.count, qn = q.count
        // Subsequence pass (every tier implies it): greedy, recording gaps and boundary hits.
        var k = 0, first = -1, last = -1, gaps = 0, boundaryHits = 0
        var j = 0
        while j < n && k < qn {
            if name[j] == q[k] {
                if first < 0 { first = j } else { gaps += j - last - 1 }
                if flags[j] & 1 != 0 { boundaryHits += 1 }
                last = j
                k += 1
            }
            j += 1
        }
        guard k == qn else { return nil }

        if n == qn { return 1000 }  // subsequence of equal length ⇒ equal
        let ratio = Float(qn) / Float(n)
        if hasPrefix(name, 0, q) {
            if stemLen == qn { return 950 }
            return 800 + 100 * ratio
        }
        // Word-boundary prefix.
        var p = 1
        while p + qn <= n {
            if flags[p] & 1 != 0 && hasPrefix(name, p, q) {
                return 600 + 80 * ratio - Float(min(30, p))
            }
            p += 1
        }
        guard qn >= 2 else { return nil }
        // Acronym: query letters matched, in order, against word-start bytes only.
        var a = 0, words = 0, firstWord = true, startsAtFirst = false
        for x in 0..<n where flags[x] & 1 != 0 {
            words += 1
            if a < qn && name[x] == q[a] {
                if firstWord { startsAtFirst = true }
                a += 1
            }
            firstWord = false
        }
        if a == qn {
            let coverage = Float(qn) / Float(max(words, qn))
            return 450 + 60 * coverage + (startsAtFirst ? 20 : 0)
        }
        // Fuzzy subsequence with gap penalty.
        let fuzzy = 300 - 12 * Float(gaps) - 2 * Float(first) + 8 * Float(boundaryHits)
        return min(299, max(10, fuzzy))
    }

    @inline(__always)
    private static func hasPrefix(
        _ name: UnsafeBufferPointer<UInt8>, _ at: Int, _ q: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        guard at + q.count <= name.count else { return false }
        return memcmp(name.baseAddress! + at, q.baseAddress!, q.count) == 0
    }

    // MARK: Folding

    /// Case- and diacritic-folds `s` into UTF-8 bytes, plus per-byte word-start flags
    /// (start of string, after a separator, camelCase hump, letter↔digit transition).
    static func fold(_ s: String) -> (bytes: [UInt8], flags: [UInt8]) {
        var bytes: [UInt8] = []
        var flags: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        flags.reserveCapacity(s.utf8.count)
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            let u = Array(s.utf8)
            for (i, c) in u.enumerated() {
                let cls = asciiClass(c)
                let prev = i > 0 ? asciiClass(u[i - 1]) : .sep
                let next = i + 1 < u.count ? asciiClass(u[i + 1]) : .sep
                bytes.append(cls == .upper ? c | 0x20 : c)
                flags.append(isBoundary(cls, prev, next) ? 1 : 0)
            }
            return (bytes, flags)
        }
        // K5: names keep their on-disk spelling (often NFD from older volumes / zip files); fold the NFC form so
        // NFD and NFC names and queries produce the same bytes.
        // K7: fullwidth ASCII forms (U+FF01–FF5E) and the ideographic space fold to ASCII ("a：b" == "a:b").
        var s = s
        if s.unicodeScalars.contains(where: { (0xFF01...0xFF5E).contains($0.value) || $0.value == 0x3000 }) {
            var v = String.UnicodeScalarView()
            for u in s.unicodeScalars {
                if (0xFF01...0xFF5E).contains(u.value), let a = Unicode.Scalar(u.value - 0xFEE0) {
                    v.append(a)
                } else if u.value == 0x3000 {
                    v.append(" ")
                } else {
                    v.append(u)
                }
            }
            s = String(v)
            if s.utf8.allSatisfy({ $0 < 0x80 }) { return fold(s) }
        }
        let chars = Array(PathKey.canonical(s))
        let classes = chars.map(charClass)
        for (i, ch) in chars.enumerated() {
            let prev = i > 0 ? classes[i - 1] : .sep
            let next = i + 1 < chars.count ? classes[i + 1] : .sep
            let folded = String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
                .precomposedStringWithCanonicalMapping
            let b = Array(folded.utf8)
            guard !b.isEmpty else { continue }
            let boundary = isBoundary(classes[i], prev, next)
            for (x, byte) in b.enumerated() {
                bytes.append(byte)
                flags.append(x == 0 && boundary ? 1 : 0)
            }
        }
        return (bytes, flags)
    }

    enum CharClass { case upper, lower, digit, sep }

    @inline(__always)
    private static func asciiClass(_ c: UInt8) -> CharClass {
        switch c {
        case 65...90: return .upper
        case 97...122: return .lower
        case 48...57: return .digit
        default: return .sep
        }
    }

    private static func charClass(_ ch: Character) -> CharClass {
        if ch.isNumber { return .digit }
        if ch.isLetter { return ch.isUppercase ? .upper : .lower }
        return .sep
    }

    @inline(__always)
    private static func isBoundary(_ c: CharClass, _ prev: CharClass, _ next: CharClass) -> Bool {
        if c == .sep { return false }
        switch prev {
        case .sep: return true
        case .lower: return c == .upper || c == .digit
        case .digit: return c != .digit
        case .upper: return (c == .upper && next == .lower) || c == .digit
        }
    }

    /// 64-bit presence mask over bytes: a–z → 0–25, 0–9 → 26–35, anything else hashed into 36–63.
    @inline(__always)
    static func mask(_ b: [UInt8]) -> UInt64 {
        var m: UInt64 = 0
        for c in b { m |= 1 << bit(c) }
        return m
    }

    @inline(__always)
    private static func bit(_ c: UInt8) -> UInt64 {
        switch c {
        case 97...122: return UInt64(c - 97)
        case 48...57: return UInt64(c - 48 + 26)
        default: return 36 + UInt64(c) % 28
        }
    }
}

/// Bounded best-k collector (limit is small: panel rows).
private struct TopK {
    let limit: Int
    var items: [(score: Float, slot: Int)] = []
    var minIndex = 0

    init(limit: Int) {
        self.limit = limit
        items.reserveCapacity(limit)
    }

    @inline(__always)
    mutating func offer(_ score: Float, _ slot: Int) {
        if items.count < limit {
            items.append((score, slot))
            if items.count == limit { recomputeMin() }
        } else if score > items[minIndex].score {
            items[minIndex] = (score, slot)
            recomputeMin()
        }
    }

    private mutating func recomputeMin() {
        var m = 0
        for i in 1..<items.count where items[i].score < items[m].score { m = i }
        minIndex = m
    }

    func sorted() -> [(score: Float, slot: Int)] {
        items.sorted { $0.score != $1.score ? $0.score > $1.score : $0.slot < $1.slot }
    }
}
