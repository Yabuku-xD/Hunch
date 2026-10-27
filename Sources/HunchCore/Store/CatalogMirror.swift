import Foundation

/// Compact in-memory copy of the `items` table (≈ 90 B per item instead of ≈ 500 B for `[UInt32: Item]`).
///
/// Paths live in one UTF-8 buffer; a name that is the path's last bytes (the common case) is stored as an offset
/// into it, anything else in a side table. `Item`s are materialized on demand (a few per result row).
struct CatalogMirror: Sendable {
    private var slotByID: [Int32] = []  // id → slot, -1 = absent
    private var pathBytes: [UInt8] = []
    private var pathStart: [UInt32] = []
    private var pathEnd: [UInt32] = []
    /// Byte offset of the name inside the path, or `UInt16.max` (name in `otherNames`).
    private var nameOffset: [UInt16] = []
    private var kinds: [UInt8] = []
    private var modified: [Double] = []
    private var ids: [UInt32] = []
    private var otherNames: [UInt32: String] = [:]
    private var dead = 0

    private(set) var count = 0

    mutating func reserve(_ n: Int) {
        pathBytes.reserveCapacity(n * 64)
        pathStart.reserveCapacity(n)
        pathEnd.reserveCapacity(n)
        nameOffset.reserveCapacity(n)
        kinds.reserveCapacity(n)
        modified.reserveCapacity(n)
        ids.reserveCapacity(n)
    }

    func item(_ id: UInt32) -> Item? {
        guard Int(id) < slotByID.count else { return nil }
        let s = slotByID[Int(id)]
        return s < 0 ? nil : item(slot: Int(s))
    }

    /// Slots in `0..<slotCount`; dead slots return nil.
    var slotCount: Int { ids.count }

    func liveItem(slot i: Int) -> Item? {
        slotByID[Int(ids[i])] == Int32(i) ? item(slot: i) : nil
    }

    private func item(slot i: Int) -> Item {
        let s = Int(pathStart[i]), e = Int(pathEnd[i])
        return pathBytes.withUnsafeBufferPointer { p in
            let path = String(decoding: p[s..<e], as: UTF8.self)
            let name =
                nameOffset[i] == UInt16.max
                ? otherNames[ids[i]] ?? ""
                : String(decoding: p[(s + Int(nameOffset[i]))..<e], as: UTF8.self)
            return Item(
                id: ids[i], path: path, name: name, kind: ItemKind(rawValue: kinds[i]) ?? .file,
                modified: Date(timeIntervalSince1970: modified[i]))
        }
    }

    mutating func insert(_ item: Item) {
        remove(item.id)
        let id = Int(item.id)
        if id >= slotByID.count {
            slotByID.append(contentsOf: repeatElement(-1, count: max(id + 1 - slotByID.count, slotByID.count / 2)))
        }
        let start = pathBytes.count
        pathBytes.append(contentsOf: item.path.utf8)
        let end = pathBytes.count
        let offset = end - start - item.name.utf8.count
        if offset >= 0, offset < Int(UInt16.max), pathBytes[(start + offset)..<end].elementsEqual(item.name.utf8) {
            nameOffset.append(UInt16(offset))
        } else {
            nameOffset.append(UInt16.max)
            otherNames[item.id] = item.name
        }
        slotByID[id] = Int32(ids.count)
        pathStart.append(UInt32(start))
        pathEnd.append(UInt32(end))
        kinds.append(item.kind.rawValue)
        modified.append(item.modified.timeIntervalSince1970)
        ids.append(item.id)
        count += 1
    }

    mutating func remove(_ id: UInt32) {
        guard Int(id) < slotByID.count, slotByID[Int(id)] >= 0 else { return }
        slotByID[Int(id)] = -1
        otherNames[id] = nil
        count -= 1
        dead += 1
        if dead > 4096 && dead * 4 > ids.count { compact() }
    }

    private mutating func compact() {
        var out = CatalogMirror()
        out.reserve(count)
        for i in 0..<slotCount { if let item = liveItem(slot: i) { out.insert(item) } }
        self = out
    }
}

/// A point-in-time view of the catalog's items (copy-on-write; iterating holds no lock and materializes one
/// `Item` at a time).
public struct CatalogItems: Sequence, Sendable {
    let mirror: CatalogMirror

    public var count: Int { mirror.count }
    public var underestimatedCount: Int { mirror.count }

    public struct Iterator: IteratorProtocol {
        let mirror: CatalogMirror
        var slot = 0

        public mutating func next() -> Item? {
            while slot < mirror.slotCount {
                defer { slot += 1 }
                if let item = mirror.liveItem(slot: slot) { return item }
            }
            return nil
        }
    }

    public func makeIterator() -> Iterator { Iterator(mirror: mirror) }
}
