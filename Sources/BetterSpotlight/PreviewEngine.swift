#if DEBUG
import Foundation
import SpotCore
import Synchronization

/// Dev-only static fixture so the UI runs without an index. Select with env `BS_FIXTURE=demo|worst|empty|one`.
/// Emits name hits first, then (after a short delay) a fused list with content and meaning hits of every kind
/// (text, OCR, transcript, video frame, semantic text, semantic image), like the real engine contract.
/// Media paths point at the research samples in /tmp/betterspotlight/m so proof crops render for real.
struct PreviewEngine: SearchEngine {
    enum Fixture: String {
        case demo, worst, empty, one
    }

    private struct Entry: Sendable {
        let item: Item
        /// Words a semantic retriever would associate with the item.
        let meaning: String
        /// Content evidence: the hit's kind, snippet and location.
        let content: (kind: ContentMatch.Kind, snippet: String, location: ContentLocation, more: Int)?
    }

    let fixture: Fixture
    let store: FixtureStore
    private let entries: [Entry]

    init?(fixture name: String) {
        guard let fixture = Fixture(rawValue: name.lowercased()) else { return nil }
        self.fixture = fixture
        entries = Self.entries(for: fixture)
        store = FixtureStore(pinned: Self.defaultPins(fixture, entries.map(\.item)),
                             recents: Self.defaultRecents(fixture, entries.map(\.item)))
    }

    func results(for q: String) -> AsyncStream<[SearchResult]> {
        begin(q, yieldNames: true).rest
    }

    func start(_ q: String) -> (first: [SearchResult]?, rest: AsyncStream<[SearchResult]>) {
        begin(q, yieldNames: false)
    }

    private func begin(_ q: String, yieldNames: Bool) -> (first: [SearchResult]?, rest: AsyncStream<[SearchResult]>) {
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchResult].self)
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixture = fixture
        let entries = entries
        guard !query.isEmpty, fixture != .empty else {
            if yieldNames { continuation.yield([]) }
            continuation.finish()
            return ([], stream)
        }
        // Names are synchronous, like the real engine's first emission.
        let names = Self.nameHits(query, entries, matchAll: fixture == .worst)
        if yieldNames { continuation.yield(names) }
        let task = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return continuation.finish() }
            continuation.yield(names + Self.contentHits(query, entries, fixture: fixture, exclude: Set(names.map(\.id))))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return (names, stream)
    }

    func suggestions() -> [SearchSection] {
        let byPath = Dictionary(entries.map { ($0.item.path, $0.item) }, uniquingKeysWith: { a, _ in a })
        let pinned = store.pinnedPaths.compactMap { byPath[$0] }
        let pinnedIDs = Set(pinned.map(\.id))
        let recents = store.recentPaths.compactMap { byPath[$0] }.filter { !pinnedIDs.contains($0.id) }.prefix(8)
        var out: [SearchSection] = []
        if !pinned.isEmpty {
            out.append(SearchSection(kind: .favorites, title: "Favorites",
                                     results: pinned.map { SearchResult(item: $0, score: 0, source: .name) }))
        }
        if !recents.isEmpty {
            out.append(SearchSection(kind: .recents, title: "Recents",
                                     results: recents.map { SearchResult(item: $0, score: 0, source: .name) }))
        }
        return out
    }

    /// Fixture status: demo indexes names, worst reads images, empty has no model.
    var status: IndexStatus {
        switch fixture {
        case .demo: IndexStatus(phase: .embedding, items: 80_112, embedded: 12_340, total: 80_112)
        case .worst: IndexStatus(phase: .idle, items: 80_112, embedded: 80_112, total: 80_112)
        case .empty: IndexStatus(phase: .modelMissing, items: 0, embedded: 0, total: 0)
        case .one: IndexStatus(phase: .idle, items: 1, embedded: 1, total: 1)
        }
    }

    var tiers: [ContentTierStatus] {
        switch fixture {
        case .worst: [ContentTierStatus(tier: .documents, done: 2_400, total: 2_400),
                      ContentTierStatus(tier: .images, done: 738, total: 1_800),
                      ContentTierStatus(tier: .speech, done: 3, total: 100)]
        default: []
        }
    }

    // MARK: Matching

    private static func nameHits(_ query: String, _ entries: [Entry], matchAll: Bool) -> [SearchResult] {
        if matchAll {
            // Worst case: every hard name row is on screen for any query, in fixture order.
            return entries.filter { $0.content == nil && $0.meaning.isEmpty }.enumerated().map { index, entry in
                SearchResult(item: entry.item, score: 1 - Float(index) * 0.01, source: .name)
            }
        }
        let q = fold(query)
        return entries.compactMap { entry -> SearchResult? in
            let name = fold(entry.item.name)
            var score: Float
            if name.hasPrefix(q) {
                score = 1.0
            } else if name.range(of: " " + q) != nil || name.range(of: "-" + q) != nil {
                score = 0.9
            } else if name.contains(q) {
                score = 0.8
            } else if isSubsequence(q.filter { !$0.isWhitespace }, of: name) {
                score = 0.5
            } else {
                return nil
            }
            if entry.item.kind == .app { score += 0.05 }
            return SearchResult(item: entry.item, score: score, source: .name)
        }
        .sorted { $0.score > $1.score }
    }

    private static func contentHits(_ query: String, _ entries: [Entry], fixture: Fixture,
                                    exclude: Set<UInt32>) -> [SearchResult] {
        let words = fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        return entries.compactMap { entry -> SearchResult? in
            guard !exclude.contains(entry.item.id), let content = entry.content else {
                guard !exclude.contains(entry.item.id), !entry.meaning.isEmpty,
                      fixture == .worst || words.contains(where: { entry.meaning.contains($0) }) else { return nil }
                return SearchResult(item: entry.item, score: 0.7, source: .semantic)
            }
            let isMeaning = content.kind == .semantic || content.kind == .image
            let highlights = isMeaning ? [] : ranges(of: words, in: content.snippet)
            let matches = fixture == .worst
                || (isMeaning ? words.contains { entry.meaning.contains($0) } : !highlights.isEmpty)
            guard matches else { return nil }
            let match = ContentMatch(kind: content.kind, snippet: content.snippet, highlights: highlights,
                                     location: content.location)
            return SearchResult(item: entry.item, score: isMeaning ? 0.7 : 0.8,
                                source: isMeaning ? .semantic : .content, match: match, moreMatches: content.more)
        }
    }

    /// UTF-16 ranges of every word occurrence (case/diacritic-insensitive).
    private static func ranges(of words: [String], in text: String) -> [Range<Int>] {
        let ns = text as NSString
        var out: [Range<Int>] = []
        for word in words {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard found.location != NSNotFound else { break }
                out.append(found.location..<(found.location + found.length))
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var cursor = haystack.startIndex
        for c in needle {
            guard let found = haystack[cursor...].firstIndex(of: c) else { return false }
            cursor = haystack.index(after: found)
        }
        return true
    }

    // MARK: Fixtures

    private static let media = "/tmp/betterspotlight/m"

    private static func entries(for fixture: Fixture) -> [Entry] {
        let home = NSHomeDirectory()
        var nextID: UInt32 = 1
        func entry(_ path: String, _ kind: ItemKind, _ meaning: String = "",
                   content: (ContentMatch.Kind, String, ContentLocation, Int)? = nil) -> Entry {
            defer { nextID += 1 }
            let item = Item(id: nextID, path: path, name: (path as NSString).lastPathComponent, kind: kind,
                            modified: Date(timeIntervalSince1970: 1_760_000_000))
            return Entry(item: item, meaning: meaning,
                         content: content.map { (kind: $0.0, snippet: $0.1, location: $0.2, more: $0.3) })
        }
        let contentEntries: [Entry] = [
            entry("\(media)/doc.pdf", .file, content: (
                .text, "Invoice INV-4471-B for one cordless drill, Acme Invoice total 226.80 incl. VAT, due 30 days",
                ContentLocation(page: 1, line: 6), 6)),
            entry("\(media)/invoice.png", .file, content: (
                .ocr, "ACME HARDWARE · INVOICE No 88 · cordless drill 18V · total 226.80",
                ContentLocation(region: ContentRegion(x: 0.05, y: 0.08, width: 0.5, height: 0.12)), 2)),
            entry("\(media)/video60.mp4", .file, content: (
                .ocr, "Acme invoice on the counter next to the drill box",
                ContentLocation(time: 23, region: ContentRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.3)), 0)),
            entry("\(media)/long.m4a", .file, content: (
                .transcript, "could you send the Acme invoice again, the drill one, I can't find it", 
                ContentLocation(time: 134), 3)),
            entry("\(media)/doc.txt", .file, "drill receipt warranty purchase invoice", content: (
                .semantic, "About a cordless drill purchase and its two-year warranty", .whole, 0)),
            entry("\(media)/red_circle.png", .file, "red circle shape logo invoice", content: (
                .image, "", .whole, 0)),
            entry("\(media)/screenshot.png", .file, content: (
                .ocr, "error: externally-managed-environment × This environment is externally managed invoice",
                ContentLocation(region: ContentRegion(x: 0.1, y: 0.4, width: 0.6, height: 0.05)), 0)),
        ]

        switch fixture {
        case .empty:
            return []
        case .one:
            return [entry("/System/Applications/Calculator.app", .app, "math numbers")]
        case .demo:
            return [
                entry("/Applications/Safari.app", .app, "browser web internet"),
                entry("/System/Applications/Calendar.app", .app, "events schedule dates"),
                entry("/System/Applications/Calculator.app", .app, "math numbers"),
                entry("/System/Applications/Notes.app", .app, "writing text"),
                entry("/System/Applications/Photos.app", .app, "pictures images"),
                entry("/System/Applications/Preview.app", .app, "pdf images viewer"),
                entry("/System/Applications/Utilities/Terminal.app", .app),
                entry("/System/Library/CoreServices/Finder.app", .app),
                entry("\(home)/Documents", .folder),
                entry("\(home)/Downloads", .folder),
                entry("\(home)/Pictures", .folder),
                entry("\(home)/Documents/Finance/Acme Hardware", .folder),
                entry("\(home)/Documents/Finance/Acme Invoices.numbers", .file),
                entry("\(home)/Pictures/Holidays/IMG_2041.jpg", .file, "golden retriever beach dog photos"),
                entry("\(home)/Documents/Taxes/2024 Tax Return.pdf", .file, "tax irs finance"),
                entry("\(home)/Documents/Notes/Project Plan.md", .file, "roadmap planning"),
            ] + contentEntries
        case .worst:
            let deep = "\(home)/Projects/Clients/Acme/2025/Q3/Deliverables/Design/Exports/Final/Approved/Print/CMYK/HighRes/Archive"
            var names = [
                entry("\(home)/Documents/Finance/2025/Aleksandra Wiśniewska-Kowalczyk Quarterly Financial Projections FINAL v12 (copy 3).xlsx", .file),
                entry("\(home)/Downloads/" + String(repeating: "MW", count: 43) + ".pdf", .file),
                entry("\(home)/Documents/تقرير الميزانية السنوية النهائي للشركة.docx", .file),
                entry("\(home)/Desktop/🎉🎂 Birthday Party Plans.pages", .file),
                entry("\(deep)/poster-final.tiff", .file),
                entry("\(home)/Desktop/a", .file),
                entry("\(home)/Desktop/../not a path\nsecond line.txt", .file),
                entry("/Volumes/Missing Drive/orphaned/unknown-thing.zzqx", .file),
                entry("/Applications/Safari.app", .app),
                entry("/System/Applications/Calculator.app", .app),
                entry("/System/Library/CoreServices/Finder.app", .app),
                entry("\(home)/Documents/Archive of Old Scanned Receipts and Warranty Cards From Every Appliance", .folder),
                entry("\(home)/Downloads", .folder),
            ]
            names += contentEntries
            names.append(entry("\(home)/Pictures/Holidays/IMG_2041.jpg", .file, "golden retriever beach dog photos"))
            return names
        }
    }

    private static func defaultPins(_ fixture: Fixture, _ items: [Item]) -> [String] {
        switch fixture {
        case .demo:
            return items.filter { ["Safari.app", "Notes.app", "Documents", "Downloads", "Terminal.app", "Finder.app"]
                .contains($0.name) }.map(\.path)
        case .worst:
            // Eight pins: long, RTL, emoji and missing names on the shelf.
            return Array(items.filter { $0.kind != .folder || $0.name.count > 20 }.prefix(8)).map(\.path)
        case .one, .empty:
            return []
        }
    }

    private static func defaultRecents(_ fixture: Fixture, _ items: [Item]) -> [String] {
        switch fixture {
        case .demo:
            return items.filter { $0.path.hasPrefix(media) || $0.name.hasPrefix("Acme") || $0.name == "Calendar.app" }
                .prefix(8).map(\.path)
        case .worst:
            return Array(items.reversed().prefix(10)).map(\.path)
        case .one, .empty:
            return []
        }
    }
}

/// Fixture pins and recents, shared by the engine (suggestions) and the fixture admin (pin/unpin, opens).
final class FixtureStore: Sendable {
    private let state: Mutex<(pinned: [String], recents: [String])>

    init(pinned: [String], recents: [String]) {
        state = Mutex((pinned, recents))
    }

    var pinnedPaths: [String] { state.withLock { $0.pinned } }
    var recentPaths: [String] { state.withLock { $0.recents } }

    func pin(_ path: String) { state.withLock { if !$0.pinned.contains(path) { $0.pinned.append(path) } } }
    func unpin(_ path: String) { state.withLock { $0.pinned.removeAll { $0 == path } } }
    func recordOpen(_ path: String) {
        state.withLock { s in
            s.recents.removeAll { $0 == path }
            s.recents.insert(path, at: 0)
        }
    }
}

/// In-memory admin for fixtures: static status, pins and recents in `FixtureStore`, roots in memory.
@MainActor
final class FixtureIndexAdmin: IndexAdmin {
    private let engine: PreviewEngine
    private(set) var roots: [URL] = [URL(fileURLWithPath: NSHomeDirectory() + "/Documents"),
                                     URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"),
                                     URL(fileURLWithPath: NSHomeDirectory() + "/Pictures")]

    let models: any ModelProviding
    private(set) var contentIndexing = true

    init(engine: PreviewEngine, models: any ModelProviding) {
        self.engine = engine
        self.models = models
    }

    private var fixtureState: (IndexStatus, [ContentTierStatus])? {
        DebugOverrides.indexState.flatMap(IndexStateFixture.make)
    }

    func statusUpdates() -> AsyncStream<IndexStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: IndexStatus.self)
        continuation.yield(fixtureState?.0 ?? engine.status)
        return stream
    }

    func contentTiers() -> [ContentTierStatus] { fixtureState?.1 ?? engine.tiers }
    func setContentIndexing(_ on: Bool) async { contentIndexing = on }
    func setRoots(_ roots: [URL]) async { self.roots = roots }
    func verifyIndex() async -> VerifyReport {
        try? await Task.sleep(for: .seconds(1))
        return VerifyReport()
    }
    func resetIndex() async { try? await Task.sleep(for: .seconds(1)) }
    func exclude(_ item: Item) async {}
    func indexNow(_ item: Item) {}
    func changes() -> AsyncStream<IndexChangeBatch> { AsyncStream { _ in } }
    func isPinned(_ item: Item) -> Bool { engine.store.pinnedPaths.contains(item.path) }
    func pin(_ item: Item) { engine.store.pin(item.path) }
    func unpin(_ item: Item) { engine.store.unpin(item.path) }
    func recordOpen(_ item: Item) { engine.store.recordOpen(item.path) }
    func setPanelVisible(_ visible: Bool) {}
    var modelDescription: String { "Not loaded" }
}

/// U14: drives every §2 `ModelState` for screenshots (`BS_MODEL_STATE`). `download()` simulates progress at 4 Hz with
/// one `Task` loop that exists only while downloading and ends at 100 %. `BS_MODEL_FROZEN=1` holds the value still.
final class FixtureModelStore: ModelProviding {
    private struct Box {
        var state: ModelState
        var listeners: [UUID: AsyncStream<ModelState>.Continuation] = [:]
        var loop: Task<Void, Never>?
    }

    private let box: Mutex<Box>
    let modelsDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/\(AppInfo.name)/Models")
    private static let total = ModelStore.downloadBytes

    init?(spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let fraction = parts.count > 1 ? Double(parts[1]) ?? 0.36 : 0.36
        let progress = Self.progress(fraction, rate: 6_000_000)
        let home = NSHomeDirectory()
        func ready(_ source: ModelSource, projector: Bool = true) -> ModelState {
            let dir = switch source {
            case .digUp: home + "/Library/Application Support/DigUp/Models/"
            case .huggingFaceCache: home + "/.cache/huggingface/hub/models--ggml-org--embeddinggemma-2-GGUF/snapshots/bfcd298/"
            default: home + "/Library/Application Support/\(AppInfo.name)/Models/"
            }
            return .ready(ResolvedModel(text: URL(fileURLWithPath: dir + ModelFile.text.fileName), textSource: source,
                                        projector: projector ? URL(fileURLWithPath: dir + ModelFile.projector.fileName) : nil,
                                        projectorSource: projector ? source : nil))
        }
        let state: ModelState
        switch parts[0] {
        case "missing": state = .missing
        case "found-digup": state = ready(.digUp)
        case "found-hf": state = ready(.huggingFaceCache)
        case "downloaded": state = ready(.downloaded)
        case "text-only": state = ready(.downloaded, projector: false)
        case "downloading": state = .downloading(progress)
        case "paused": state = .paused(progress)
        case "verifying": state = .verifying(.projector)
        case "failed-offline": state = .failed(.offline, progress: progress)
        case "failed-checksum": state = .failed(.checksum(.text), progress: nil)
        case "failed-disk": state = .failed(.diskFull(needed: 1_200_000_000, available: 0), progress: nil)
        case "failed-http": state = .failed(.http(status: 503), progress: nil)
        default: return nil
        }
        box = Mutex(Box(state: state))
        if case .downloading = state { startLoop() }
    }

    private static func progress(_ fraction: Double, rate: Double?) -> DownloadProgress {
        let received = Int64(Double(total) * min(max(fraction, 0), 1))
        return DownloadProgress(file: received < ModelFile.text.byteCount ? .text : .projector,
                                receivedBytes: received, totalBytes: total, bytesPerSecond: rate)
    }

    var state: ModelState { box.withLock { $0.state } }

    func states() -> AsyncStream<ModelState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelState.self)
        let id = UUID()
        box.withLock {
            continuation.yield($0.state)
            $0.listeners[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in self?.box.withLock { _ = $0.listeners.removeValue(forKey: id) } }
        return stream
    }

    private func set(_ next: ModelState) {
        let listeners = box.withLock { b -> [AsyncStream<ModelState>.Continuation] in
            b.state = next
            return Array(b.listeners.values)
        }
        for l in listeners { l.yield(next) }
    }

    private var fraction: Double {
        switch state {
        case .downloading(let p), .paused(let p): p.fraction
        case .failed(_, let p?): p.fraction
        default: 0
        }
    }

    private func startLoop() {
        guard !DebugOverrides.modelFrozen else { return }
        let task = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250)) // 4 Hz frequency gate
                guard !Task.isCancelled, case .downloading(let p) = self.state else { return }
                let next = p.fraction + 0.01
                if next >= 1 {
                    self.set(.verifying(.projector))
                    try? await Task.sleep(for: .seconds(1))
                    let dir = NSHomeDirectory() + "/Library/Application Support/\(AppInfo.name)/Models/"
                    self.set(.ready(ResolvedModel(
                        text: URL(fileURLWithPath: dir + ModelFile.text.fileName), textSource: .downloaded,
                        projector: URL(fileURLWithPath: dir + ModelFile.projector.fileName), projectorSource: .downloaded)))
                    return
                }
                self.set(.downloading(Self.progress(next, rate: 6_000_000)))
            }
        }
        box.withLock { $0.loop?.cancel(); $0.loop = task }
    }

    private func stopLoop() { box.withLock { $0.loop?.cancel(); $0.loop = nil } }

    func download() {
        switch state {
        case .ready, .downloading, .verifying: return
        default: break
        }
        set(.downloading(Self.progress(fraction, rate: nil)))
        startLoop()
    }

    func pause() {
        guard case .downloading(let p) = state else { return }
        stopLoop()
        set(.paused(p))
    }

    func cancel() {
        stopLoop()
        set(.missing)
    }

    func remove() async throws {
        stopLoop()
        set(.missing)
    }

    func importFiles(_ urls: [URL]) async throws -> ResolvedModel {
        throw ModelStoreError.io("fixture")
    }
}
#endif
