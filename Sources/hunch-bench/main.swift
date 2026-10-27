import Foundation
import HunchCore

// Benchmarks against the research targets (owner: integrate).
//
//   hunch-bench --synthetic   latency targets (name / vector / embed / load / crawl)
//   hunch-bench --memory      resident memory of a 200k-item index, with the model loaded and unloaded
//   hunch-bench --content     content indexing: text files/s, OCR, image vectors, video, speech, full-text (Content.swift)
//   hunch-bench --embed-dump <out.json>  vectors of 20 fixed strings (cross-build equality check, RELEASING.md)
//   hunch-bench --incremental no-rebuild gates (v3 plan §C): restart, moves, copies, append, new files, journal loss,
//                            idle, touch (Incremental.swift); exit 1 on a missed target
//
// stdout carries exactly the metric lines (key=value); progress and errors go to stderr.

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--memory-measure"), i + 2 < args.count {
    await memoryMeasure(
        directory: URL(fileURLWithPath: args[i + 1], isDirectory: true),
        dimension: Int(args[i + 2]) ?? 256)
    exit(0)
}
if let i = args.firstIndex(of: "--incremental-cold-child"), i + 2 < args.count {
    await incrementalColdChild(state: URL(fileURLWithPath: args[i + 1], isDirectory: true), tree: args[i + 2])
    exit(0)
}
if let i = args.firstIndex(of: "--incremental-child"), i + 3 < args.count {
    await incrementalChild(
        state: URL(fileURLWithPath: args[i + 1], isDirectory: true), tree: args[i + 2],
        idleSeconds: Double(args[i + 3]) ?? 60)
    exit(0)
}
// O6 gate (d): 20 fixed strings → JSON vectors, compared across llama builds (xcframework vs Homebrew).
/// Returns the exit code; the embedder is released before `exit`, because ggml's Metal device asserts when a model
/// is still loaded while the process tears down.
func embedDump(to path: String) async -> Int32 {
    let strings = [
        "dog photos", "tax return 2023", "beach holiday pictures", "quarterly budget spreadsheet",
        "meeting notes from last week", "resume pdf", "wedding photos", "lease agreement", "flight itinerary",
        "invoice from contractor", "birthday party video", "swift package manifest", "python data analysis",
        "screenshot of error", "podcast episode recording", "lecture slides", "thesis chapter draft",
        "insurance claim", "passport scan", "workout plan",
    ]
    do {
        let embedder = try await LlamaEmbedder.load(modelURL: Paths.modelURL, dimension: 256)
        let queries = try await embedder.embedQueries(Array(strings.prefix(10)))
        let docs = try await embedder.embedDocuments(
            strings.suffix(10).map { NameDocument.make(path: "/Users/bench/\($0).txt", kind: .file) })
        let vectors = (queries + docs).map { $0.map(Double.init) }
        let json = try JSONSerialization.data(withJSONObject: ["strings": strings, "vectors": vectors])
        try json.write(to: URL(fileURLWithPath: path))
        print("embed_dump_vectors=\(vectors.count)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("embed-dump failed: \(error)\n".utf8))
        return 1
    }
}
if let i = args.firstIndex(of: "--embed-eval"), i + 3 < args.count {
    exit(await embedEval(model: args[i + 1], input: args[i + 2], output: args[i + 3]))
}
if let i = args.firstIndex(of: "--embed-dump"), i + 1 < args.count {
    exit(await embedDump(to: args[i + 1]))
}
let runSynthetic = args.contains("--synthetic")
let runMemory = args.contains("--memory")
let runContent = args.contains("--content")
let runIncremental = args.contains("--incremental")
guard runSynthetic || runMemory || runContent || runIncremental else {
    FileHandle.standardError.write(
        Data(
            """
            usage: hunch-bench [--synthetic] [--memory] [--content]
                              [--incremental [--gen <dir>] [--files N] [--seed N] [--runs N] [--idle-seconds S] [--real-model]]

            """.utf8))
    exit(2)
}

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func p95(_ samples: [Double]) -> Double {
    let s = samples.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
}

func fmt(_ x: Double) -> String { x.isNaN ? "nan" : String(format: "%.3f", x) }

func millis(_ body: () throws -> Void) rethrows -> Double {
    let t0 = ContinuousClock.now
    try body()
    return (ContinuousClock.now - t0) / .milliseconds(1)
}

func millis(_ body: () async throws -> Void) async rethrows -> Double {
    let t0 = ContinuousClock.now
    try await body()
    return (ContinuousClock.now - t0) / .milliseconds(1)
}

/// Deterministic xorshift so runs are comparable.
struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

var rng = RNG(state: 0x9E37_79B9_7F4A_7C15)

// MARK: Synthetic paths

let words = [
    "invoice", "report", "budget", "notes", "meeting", "project", "draft", "final", "summary", "photo",
    "holiday", "beach", "family", "resume", "contract", "tax", "return", "receipt", "presentation",
    "design", "mockup", "screenshot", "recording", "podcast", "lecture", "thesis", "chapter", "paper",
    "analysis", "dataset", "backup", "archive", "config", "readme", "changelog", "roadmap", "proposal",
    "quarterly", "annual", "weekly", "agenda", "minutes", "letter", "statement", "insurance", "lease",
    "passport", "ticket", "itinerary", "recipe", "workout", "garden", "wedding", "birthday", "kitchen",
]
let exts = [
    "pdf", "docx", "xlsx", "pptx", "txt", "md", "jpg", "jpeg", "png", "heic", "mov", "mp4", "mp3", "m4a",
    "zip", "swift", "py", "js", "json", "csv", "key", "pages", "numbers", "rtf", "html",
]
let tops = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Developer", "Projects"]
let apps = [
    "Safari", "Mail", "Calendar", "Notes", "Xcode", "Visual Studio Code", "Slack", "Figma", "Spotify",
    "Photoshop", "Pages", "Numbers", "Keynote", "Terminal", "Preview", "Music", "Photos", "Messages",
    "Final Cut Pro", "Logic Pro", "Discord", "Zoom", "Notion", "Obsidian", "1Password", "Arc", "Firefox",
]

@MainActor func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }

@MainActor func syntheticName() -> String {
    switch Int.random(in: 0..<10, using: &rng) {
    case 0: return "IMG_\(Int.random(in: 1000...9999, using: &rng)).\(pick(["jpg", "heic", "png", "mov"]))"
    case 1:
        return
            "Screenshot 2024-0\(Int.random(in: 1...9, using: &rng))-1\(Int.random(in: 0...9, using: &rng)) at 10.\(Int.random(in: 10...59, using: &rng)).png"
    case 2:
        return
            "\(pick(words).capitalized) \(pick(words).capitalized) \(Int.random(in: 2015...2025, using: &rng)).\(pick(exts))"
    case 3: return "\(pick(words))_\(pick(words))_v\(Int.random(in: 1...9, using: &rng)).\(pick(exts))"
    case 4: return "\(pick(words))-\(pick(words))-\(pick(words)).\(pick(exts))"
    default: return "\(pick(words).capitalized)\(pick(words).capitalized).\(pick(exts))"
    }
}

let home = "/Users/bench"
var items: [Item] = []
items.reserveCapacity(200_000)
let epoch = Date(timeIntervalSince1970: 1_700_000_000)
for a in apps {
    items.append(
        Item(
            id: UInt32(items.count + 1), path: "/Applications/\(a).app", name: "\(a).app", kind: .app,
            modified: epoch))
}
var folders: [String] = tops.map { "\(home)/\($0)" }
while items.count < 200_000 {
    if Int.random(in: 0..<12, using: &rng) == 0 {
        let parent = pick(folders)
        let name = "\(pick(words).capitalized) \(Int.random(in: 1...99, using: &rng))"
        let path = "\(parent)/\(name)"
        folders.append(path)
        items.append(
            Item(
                id: UInt32(items.count + 1), path: path, name: name, kind: .folder,
                modified: epoch.addingTimeInterval(Double(items.count))))
    } else {
        let name = syntheticName()
        items.append(
            Item(
                id: UInt32(items.count + 1), path: "\(pick(folders))/\(name)", name: name, kind: .file,
                modified: epoch.addingTimeInterval(Double(items.count))))
    }
}

// Query mix: prefixes, whole words, multi-word, acronyms, typos, app names.
@MainActor func syntheticQuery() -> String {
    switch Int.random(in: 0..<6, using: &rng) {
    case 0: return String(pick(words).prefix(Int.random(in: 1...4, using: &rng)))
    case 1: return pick(words)
    case 2: return "\(pick(words)) \(pick(words))"
    case 3: return String(pick(apps).lowercased().prefix(Int.random(in: 2...6, using: &rng)))
    case 4:
        var w = Array(pick(words))
        if w.count > 3 { w.swapAt(1, 2) }
        return String(w)
    default: return "\(pick(words).prefix(1))\(pick(words).prefix(1))\(pick(words).prefix(1))"
    }
}

if runSynthetic {
    // MARK: 1. Name index

    let nameIndex = NameIndex()
    let buildMs = millis { nameIndex.replaceAll(items) }
    note("name index build: \(fmt(buildMs)) ms for \(nameIndex.count) items")
    let nameQueries = (0..<500).map { _ in syntheticQuery() }
    for q in nameQueries.prefix(20) { _ = nameIndex.search(q, limit: 50) }  // warm caches
    let nameSamples = nameQueries.map { q in millis { _ = nameIndex.search(q, limit: 50) } }
    print("name_p95_ms=\(fmt(p95(nameSamples))) items=\(items.count)")

    // MARK: 2. Vector store

    let dim = 256
    @MainActor func randomUnit() -> [Float] {
        var v = (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        for i in v.indices { v[i] /= n }
        return v
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hunch-bench-\(getpid())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    do {
        var store: VectorStore? = try VectorStore(directory: tmp, dimension: dim)
        let fillMs = try await millis {
            for chunk in stride(from: 0, to: 100_000, by: 10_000) {
                let batch = (chunk..<chunk + 10_000).map { (id: Chunk.id(item: UInt32($0 + 1)), vector: randomUnit()) }
                try await store!.upsert(batch)
            }
        }
        note("vector fill: \(fmt(fillMs)) ms for \(await store!.count) vectors")
        let vq = (0..<500).map { _ in randomUnit() }
        for q in vq.prefix(10) { _ = await store!.topK(q, k: 50) }
        var vectorSamples: [Double] = []
        for q in vq {
            vectorSamples.append(await millis { _ = await store!.search(q, k: 50) })
        }
        let n = await store!.count
        print("vector_p95_ms=\(fmt(p95(vectorSamples))) vectors=\(n)")

        await store!.flush()
        store = nil
        var reopened: VectorStore?
        let loadMs = try millis { reopened = try VectorStore(directory: tmp, dimension: dim) }
        let reloaded = await reopened!.count
        if reloaded != n { note("WARNING: reopened store has \(reloaded) vectors, expected \(n)") }
        // Printed after the embed metrics to keep the requested line order.
        let vectorLoadLine = "vector_load_ms=\(fmt(loadMs))"
        reopened = nil

        // MARK: 3. Embedder

        var embedLines = ["query_embed_p95_ms=nan", "doc_embed_per_sec=nan"]
        do {
            let embedder = try await LlamaEmbedder.load(modelURL: Paths.modelURL, dimension: dim)
            let realQueries = [
                "dog photos", "tax return 2023", "beach holiday pictures", "quarterly budget spreadsheet",
                "meeting notes from last week", "resume pdf", "wedding photos", "lease agreement", "flight itinerary",
                "invoice from contractor", "birthday party video", "swift package manifest", "python data analysis",
                "screenshot of error", "podcast episode recording", "lecture slides", "thesis chapter draft",
                "insurance claim", "passport scan", "workout plan", "garden layout sketch", "kitchen renovation",
                "project roadmap", "annual report", "design mockups", "music production session", "recipe for pasta",
                "bank statement", "medical records", "car insurance", "apartment photos", "concert tickets",
                "book manuscript", "conference talk", "expense report", "product requirements", "release notes",
                "home network diagram", "family tree", "vacation budget", "grocery list", "piano sheet music",
                "travel checklist", "job offer letter", "salary negotiation", "photo editing app", "code editor",
                "video calls", "password manager", "web browser",
            ]
            var querySamples: [Double] = []
            for q in realQueries {
                querySamples.append(try await millis { _ = try await embedder.embedQueries([q]) })
            }
            let docs = items.prefix(64 * 16).map { NameDocument.make(path: $0.path, kind: $0.kind) }
            _ = try await embedder.embedDocuments(Array(docs.prefix(64)))  // warm the batch shape
            let docMs = try await millis {
                for start in stride(from: 0, to: docs.count, by: 64) {
                    _ = try await embedder.embedDocuments(Array(docs[start..<min(start + 64, docs.count)]))
                }
            }
            embedLines = [
                "query_embed_p95_ms=\(fmt(p95(querySamples)))",
                "doc_embed_per_sec=\(fmt(Double(docs.count) / (docMs / 1000)))",
            ]
        } catch {
            note("embedder unavailable (\(error)); set HUNCH_MODEL to the gguf path")
        }
        embedLines.forEach { print($0) }
        print(vectorLoadLine)
    } catch {
        note("vector store failed: \(error)")
        exit(1)
    }

    // MARK: 4. Crawl

    let crawler = Crawler(roots: [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications")])
    let (_, stats) = await crawler.crawlEntries()
    note("crawl: \(stats.count) items in \(fmt(stats.seconds * 1000)) ms")
    print("crawl_items_per_sec=\(fmt(stats.itemsPerSecond))")
}

if runMemory {
    // Hand the only reference to the items over, so the build can free them before the measuring child starts.
    func takeItems() -> [Item] {
        defer { items = [] }
        return items
    }
    await memoryBench(takeItems(), dimension: 256)
}

if runContent {
    await contentBench()
}

if runIncremental {
    let code = await incrementalBench()
    if code != 0 { exit(code) }
}
