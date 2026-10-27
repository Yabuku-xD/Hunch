import Darwin
import Foundation
import HunchCore

/// (resident, physical footprint) of this process in MiB.
func memoryMB() -> (rss: Double, footprint: Double) {
    var usage = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &usage) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    guard rc == 0 else { return (.nan, .nan) }
    return (Double(usage.ri_resident_size) / 1_048_576, Double(usage.ri_phys_footprint) / 1_048_576)
}

/// Returns freed heap to the OS, then lets things settle, so the reading reflects live memory.
func settle() async {
    malloc_zone_pressure_relief(nil, 0)
    try? await Task.sleep(for: .milliseconds(500))
}

private func unitVector(_ d: Int, _ rng: inout RNG) -> [Float] {
    var v = (0..<d).map { _ in Float.random(in: -1...1, using: &rng) }
    let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
    for i in v.indices { v[i] /= n }
    return v
}

/// `--memory`: builds a 200k-item index on disk (catalog + one name vector per item), drops it, reopens it the way
/// the app does at launch (catalog mirror + name index + mmapped vectors, model not loaded) and reports RSS idle,
/// with the model loaded, the model load time and RSS after unloading.
/// `items` is consumed: the caller's copy is gone, so dropping it here frees the synthetic list before measuring.
func memoryBench(_ items: consuming [Item], dimension: Int) async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hunch-bench-mem-\(getpid())",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("index.sqlite")
    var rng = RNG(state: 0x5EED_1234_ABCD_9876)
    do {
        let catalog = try Catalog(url: url)
        let stored = try catalog.upsert(items)
        items = []
        try catalog.markEmbedded(stored.map(\.id))
        let store = try VectorStore(directory: dir, dimension: dimension)
        for start in stride(from: 0, to: stored.count, by: 10_000) {
            let batch = stored[start..<min(start + 10_000, stored.count)].map {
                (id: Chunk.id(item: $0.id), vector: unitVector(dimension, &rng))
            }
            try await store.upsert(batch)
        }
        await store.flush()
        note("memory: built \(stored.count) items + \(await store.count) vectors")
    } catch {
        note("memory build failed: \(error)")
        exit(1)
    }
    // Measure in a fresh process, like an app launch on an existing index (the build's heap and SQLite caches
    // would otherwise be counted).
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["--memory-measure", dir.path, String(dimension)]
    do {
        try child.run()
        child.waitUntilExit()
    } catch {
        note("couldn't launch the measuring process: \(error)")
        exit(1)
    }
    if child.terminationStatus != 0 { exit(child.terminationStatus) }
}

/// `--memory-measure <dir> <dimension>`: the launch-state half of `--memory`.
func memoryMeasure(directory dir: URL, dimension: Int) async {
    let url = dir.appendingPathComponent("index.sqlite")
    var rng = RNG(state: 0x0DD_BA11)

    // Launch state: what SearchBackend holds once names are loaded, before any model use.
    let catalog: Catalog
    let names = NameIndex()
    let vectors: VectorStore
    func stage(_ label: String) {
        let m = memoryMB(); note("memory: \(label): rss \(fmt(m.rss)) footprint \(fmt(m.footprint))")
    }
    stage("baseline")
    do {
        catalog = try Catalog(url: url)
        stage("catalog")
        names.replaceAll(catalog.items)
        malloc_zone_pressure_relief(nil, 0)
        stage("names")
        vectors = try VectorStore(directory: dir, dimension: dimension)
        stage("vectors")
    } catch {
        note("memory reopen failed: \(error)")
        exit(1)
    }
    for q in ["invoice", "rep", "tax return", "saf", "screenshot"] { _ = names.search(q, limit: 50) }
    _ = await vectors.search(unitVector(dimension, &rng), k: 50)  // touches every mapped vector page
    await settle()
    let hot = memoryMB()
    note("memory: right after a vector search (all vector pages resident): rss \(fmt(hot.rss)) MiB")
    // The backend's idle state: model unloaded and the vector mapping's resident pages handed back to the file cache.
    await vectors.releaseResidentPages()
    await settle()
    let idle = memoryMB()
    note(
        "memory: idle with \(catalog.count) items, \(names.count) names, \(await vectors.count) vectors; "
            + "footprint \(fmt(idle.footprint)) MiB")
    print("rss_idle_mb=\(fmt(idle.rss))")
    print("rss_idle_hot_mb=\(fmt(hot.rss))")

    var lines = ["rss_model_mb=nan", "model_load_ms=nan", "rss_after_unload_mb=nan"]
    if let model = Paths.resolveModel() {
        let embedder = ManagedEmbedder(modelURL: model, dimension: dimension)
        do {
            let t0 = ContinuousClock.now
            try await embedder.preload()
            let loadMs = (ContinuousClock.now - t0) / .milliseconds(1)
            _ = try await embedder.embedQueries(["dog photos"])
            await settle()
            let loaded = memoryMB()
            await embedder.unload()
            await settle()
            let after = memoryMB()
            if CommandLine.arguments.contains("--memory-cycles")
                || ProcessInfo.processInfo.environment["HUNCH_MEM_CYCLES"] != nil
            {
                for cycle in 2...4 {
                    try await embedder.preload()
                    _ = try await embedder.embedQueries(["cycle \(cycle)"])
                    await embedder.unload()
                    await settle()
                    note(
                        "memory: after load/unload cycle \(cycle): rss \(fmt(memoryMB().rss)) footprint \(fmt(memoryMB().footprint))"
                    )
                }
            }
            note("memory: footprint model \(fmt(loaded.footprint)) MiB, after unload \(fmt(after.footprint)) MiB")
            lines = [
                "rss_model_mb=\(fmt(loaded.rss))", "model_load_ms=\(fmt(loadMs))",
                "rss_after_unload_mb=\(fmt(after.rss))",
            ]
        } catch {
            note("model load failed: \(error)")
        }
    } else {
        note("no embedding model found; set HUNCH_MODEL to the gguf path")
    }
    lines.forEach { print($0) }
    withExtendedLifetime((catalog, names, vectors)) {}
}
