import Foundation

/// I8: `names.bin`, the folded name index on disk, so a launch maps one file instead of re-folding every catalog
/// name. Written atomically (tmp + rename). Read with `Data(.alwaysMapped)` and validated end to end (magic, version,
/// catalog generation, array sizes, FNV-1a checksum of the payload); any mismatch returns nil and the caller falls
/// back to the catalog load, so a corrupt, truncated, old or foreign file can never crash or serve stale names.
///
/// Layout v1 (little-endian): header { magic "BSNS", version u32, generation u64, rows u64, bytes u64, checksum u64 }
/// then arrays: bytes u8[B], flags u8[B], starts u32[N+1], stemLens u32[N], masks u64[N], ids u32[N], kinds u8[N],
/// primary i32[N], frecency f32[N], frecencyAt f64[N], lastUsed f64[N].
enum NameSnapshot {
    static let magic: UInt32 = 0x534E_5342
    static let version: UInt32 = 1
    static let headerSize = 40

    /// Content generation of a catalog: changes whenever any item's id, name, kind or date changes, or the
    /// preferred languages (localized app aliases) change. Exact, so a match can never serve a stale name.
    static func generation(of items: some Sequence<Item>, languages: [String] = AppNames.preferredLanguages) -> UInt64 {
        var h = FNV()
        h.add(UInt64(version))
        for l in languages { h.add(bytes: Array(l.utf8)); h.add(0) }
        for item in items {
            h.add(UInt64(item.id) << 8 | UInt64(item.kind.rawValue))
            h.add(item.modified.timeIntervalSinceReferenceDate.bitPattern)
            h.add(bytes: Array(item.name.utf8))
        }
        return h.value
    }

    static func encode(_ s: NameIndex.Storage, generation: UInt64) -> Data {
        let n = s.ids.count
        var payload = Data()
        payload.reserveCapacity(s.bytes.count * 2 + n * 45)
        func put<T>(_ a: [T]) { a.withUnsafeBytes { payload.append(contentsOf: $0) } }
        put(s.bytes); put(s.flags); put(s.starts); put(s.stemLens); put(s.masks); put(s.ids); put(s.kinds)
        put(s.primary); put(s.frecency); put(s.frecencyAt); put(s.lastUsed)
        var h = FNV()
        payload.withUnsafeBytes { h.add(bytes: $0) }
        var out = Data()
        func header<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
        header(magic); header(version); header(generation); header(UInt64(n)); header(UInt64(s.bytes.count))
        header(h.value)
        out.append(payload)
        return out
    }

    static func decode(_ data: Data, generation: UInt64) -> NameIndex.Storage? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { raw -> NameIndex.Storage? in
            func u32(_ at: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
            func u64(_ at: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
            guard u32(0) == magic, u32(4) == version, u64(8) == generation else { return nil }
            let n64 = u64(16), b64 = u64(24)
            guard n64 < 1 << 31, b64 < 1 << 32 else { return nil }
            let n = Int(n64), b = Int(b64)
            let size = 2 * b + 4 * (n + 1) + 4 * n + 8 * n + 4 * n + n + 4 * n + 4 * n + 8 * n + 8 * n
            guard raw.count == headerSize + size else { return nil }
            let payload = UnsafeRawBufferPointer(rebasing: raw[headerSize...])
            var h = FNV()
            h.add(bytes: payload)
            guard h.value == u64(32) else { return nil }
            var at = 0
            func take<T>(_ count: Int, _: T.Type) -> [T] {
                let a = [T](unsafeUninitializedCapacity: count) { buf, done in
                    if count > 0 {
                        memcpy(buf.baseAddress!, payload.baseAddress! + at, count * MemoryLayout<T>.stride)
                    }
                    done = count
                }
                at += count * MemoryLayout<T>.stride
                return a
            }
            var s = NameIndex.Storage()
            s.bytes = take(b, UInt8.self)
            s.flags = take(b, UInt8.self)
            s.starts = take(n + 1, UInt32.self)
            s.stemLens = take(n, UInt32.self)
            s.masks = take(n, UInt64.self)
            s.ids = take(n, UInt32.self)
            s.kinds = take(n, UInt8.self)
            s.primary = take(n, Int32.self)
            s.frecency = take(n, Float.self)
            s.frecencyAt = take(n, Double.self)
            s.lastUsed = take(n, Double.self)
            // Structural checks: offsets monotone and in range, primaries point at primary rows of the same id.
            guard s.starts.first == 0, s.starts.last == UInt32(b) else { return nil }
            for i in 0..<n where s.starts[i] > s.starts[i + 1] { return nil }
            s.alive = [Bool](repeating: true, count: n)
            s.slot.reserveCapacity(n)
            for i in 0..<n {
                let p = Int(s.primary[i])
                guard p >= 0, p <= i, s.primary[p] == Int32(p), s.ids[p] == s.ids[i] else { return nil }
                if p == i {
                    guard s.slot.updateValue(Int32(i), forKey: s.ids[i]) == nil else { return nil }
                } else {
                    s.aliasSlots[s.ids[i], default: []].append(Int32(i))
                }
            }
            return s
        }
    }

    static func write(_ s: NameIndex.Storage, generation: UInt64, to url: URL) throws {
        let data = encode(s.dead > 0 ? s.compacted() : s, generation: generation)
        let tmp = url.appendingPathExtension("tmp-\(getpid())")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func read(_ url: URL, generation: UInt64) -> NameIndex.Storage? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return decode(data, generation: generation)
    }

    struct FNV {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        mutating func add(_ v: UInt64) { withUnsafeBytes(of: v) { add(bytes: $0) } }
        mutating func add(bytes: some Sequence<UInt8>) {
            for b in bytes { value = (value ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        }
    }
}

extension NameIndex {
    /// I8: replaces the index with `names.bin` when it matches `generation`; false (index untouched) otherwise.
    public func loadSnapshot(_ url: URL, generation: UInt64) -> Bool {
        guard let s = NameSnapshot.read(url, generation: generation) else { return false }
        replaceStorage(s)
        return true
    }

    /// Writes the current index to `url` atomically.
    public func writeSnapshot(_ url: URL, generation: UInt64) throws {
        try NameSnapshot.write(currentStorage(), generation: generation, to: url)
    }

    public static func snapshotGeneration(of items: some Sequence<Item>) -> UInt64 {
        NameSnapshot.generation(of: items)
    }
}
