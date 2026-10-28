import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import HunchCore

// MARK: Fixtures

private func scratch(_ tag: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ModelStoreTests-\(tag)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ data: Data, _ dir: URL, _ name: String) -> URL {
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try! data.write(to: url)
    return url
}

/// Deterministic, non-repeating bytes.
private func payload(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ ($0 >> 8)) })
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A small two-file table served by `StubServer` at a per-test host.
private struct ModelFixture {
    let host = "models-\(UUID().uuidString.lowercased()).test"
    let text = payload(1_000, seed: 1)
    let projector = payload(2_000, seed: 2)

    func specs(textSHA: String? = nil) -> [ModelFile: ModelFileSpec] {
        [
            .text: ModelFileSpec(
                fileName: "t.gguf", byteCount: Int64(text.count), sha256: textSHA ?? hex(text),
                remoteURL: URL(string: "https://\(host)/t.gguf")!),
            .projector: ModelFileSpec(
                fileName: "p.gguf", byteCount: Int64(projector.count), sha256: hex(projector),
                remoteURL: URL(string: "https://\(host)/p.gguf")!),
        ]
    }

    var total: Int64 { Int64(text.count + projector.count) }

    func store(
        home: URL, environment: [String: String] = [:], textSHA: String? = nil,
        capacity: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max }
    ) -> ModelStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return ModelStore(
            home: home, environment: environment, configuration: config, specs: specs(textSHA: textSHA),
            capacity: capacity, monitorsNetwork: false)
    }

    func serve(failWith error: URLError.Code? = nil) {
        StubProtocol.servers.withLock {
            $0[host] = StubServer(files: ["/t.gguf": text, "/p.gguf": projector], failure: error)
        }
    }

    var requests: [StubRequest] { StubProtocol.servers.withLock { $0[host]?.requests ?? [] } }
}

private struct StubRequest: Sendable { let path: String; let range: String? }

private struct StubServer: Sendable {
    var files: [String: Data]
    var failure: URLError.Code?
    var requests: [StubRequest] = []
}

/// Serves fixture files over a fake host, honouring `Range: bytes=N-` with 206 + Content-Range.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let server = Self.servers.withLock { s -> StubServer? in
            s[host]?.requests.append(StubRequest(path: url.path, range: range))
            return s[host]
        }
        if let code = server?.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let data = server?.files[url.path] else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var status = 200
        var body = data
        var headers = ["Content-Length": "\(data.count)", "Accept-Ranges": "bytes"]
        if let range, range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            guard start < data.count else {
                let r = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            status = 206
            body = data.subdata(in: start..<data.count)
            headers["Content-Length"] = "\(body.count)"
            headers["Content-Range"] = "bytes \(start)-\(data.count - 1)/\(data.count)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func waitFor(
    _ store: ModelStore, timeout: Duration = .seconds(10),
    _ done: (ModelState) -> Bool
) async -> ModelState {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if done(store.state) { return store.state }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return store.state
}

private func modelsDir(_ home: URL) -> URL { home.appendingPathComponent(".hunch/models") }

// MARK: Tests

@Suite struct ModelStoreTests {
    @Test func pinnedTableMatchesTheSpec() {
        #expect(ModelFile.text.fileName == "embeddinggemma-2-Q8_0.gguf")
        #expect(ModelFile.projector.fileName == "mmproj-embeddinggemma-2-Q8_0.gguf")
        #expect(ModelFile.text.byteCount + ModelFile.projector.byteCount == ModelStore.downloadBytes)
        #expect(
            ModelFile.text.remoteURL.absoluteString
                == "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf"
        )
        #expect(ModelFile.projector.sha256 == "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    }

    /// 1. Only ~/.hunch/models (and the dev override) count; copies elsewhere and wrong byte counts are ignored.
    @Test func resolutionOrder() throws {
        let fx = ModelFixture()
        let home = scratch("order")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(fx.store(home: home).resolve() == nil)
        #expect(fx.store(home: home).state == .missing)

        // Another app's copy (DigUp) is not used: Hunch downloads its own.
        _ = write(fx.text, home.appendingPathComponent("Library/Application Support/DigUp/Models"), "t.gguf")
        #expect(fx.store(home: home).resolve() == nil)

        // Wrong byte count in our own folder: skipped.
        _ = write(fx.text.prefix(999), modelsDir(home), "t.gguf")
        #expect(fx.store(home: home).resolve() == nil)

        let ownText = write(fx.text, modelsDir(home), "t.gguf")
        var r = try #require(fx.store(home: home).resolve())
        #expect(r.text == ownText && r.textSource == .downloaded && r.projector == nil && !r.hasProjector)
        let ownProjector = write(fx.projector, modelsDir(home), "p.gguf")
        r = try #require(fx.store(home: home).resolve())
        #expect(r.projector == ownProjector && r.projectorSource == .downloaded)

        // Override wins, unverified, even with an odd size.
        let odd = write(Data("x".utf8), home, "dev.gguf")
        r = try #require(fx.store(home: home, environment: ["HUNCH_MODEL": odd.path]).resolve())
        #expect(r.text == odd && r.textSource == .override)
        // A missing override falls through.
        r = try #require(fx.store(home: home, environment: ["HUNCH_MODEL": "/nope.gguf"]).resolve())
        #expect(r.textSource == .downloaded)
    }

    /// 2. Streamed SHA-256 over 4 MiB chunks equals the one-shot digest (3 chunks).
    @Test func sha256OfThreeChunkFixture() async throws {
        let dir = scratch("sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = payload(4 * 1024 * 1024 * 2 + 4_321, seed: 9)
        let url = write(data, dir, "three-chunks.bin")
        #expect(try await ModelStore.sha256(of: url) == hex(data))
        #expect(
            try await ModelStore.sha256(of: write(Data("abc".utf8), dir, "abc"))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// verifyCandidates: a file with the right size but the wrong hash is recorded in .verified.json and skipped.
    @Test func verifyCandidatesSkipsBadHashes() async throws {
        let fx = ModelFixture()
        let home = scratch("verify")
        defer { try? FileManager.default.removeItem(at: home) }
        var corrupt = fx.text
        corrupt[10] ^= 0xFF
        _ = write(corrupt, modelsDir(home), "t.gguf")
        let store = fx.store(home: home)
        #expect(store.resolve()?.textSource == .downloaded)  // stat-only: size matches
        #expect(await store.verifyCandidates() == nil)
        #expect(store.state == .missing)
        // The verdict persists (fresh store, no hashing needed).
        #expect(fx.store(home: home).resolve() == nil)
        #expect(FileManager.default.fileExists(atPath: modelsDir(home).appendingPathComponent(".verified.json").path))
    }

    /// 3. Resume from a truncated .partial: the request asks for the rest with Range, and the file verifies.
    @Test func resumesFromTruncatedPartial() async throws {
        let fx = ModelFixture()
        fx.serve()
        let home = scratch("resume")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = write(fx.text.prefix(400), modelsDir(home), "t.gguf.partial")
        let store = fx.store(home: home)
        guard case .paused(let p) = store.state else {
            Issue.record("expected .paused after relaunch with a .partial, got \(store.state)")
            return
        }
        #expect(p.receivedBytes == 400 && p.totalBytes == fx.total)

        let observed = Mutex<[ModelState]>([])
        let stream = store.states()
        let watcher = Task {
            for await s in stream {
                observed.withLock { $0.append(s) }
                if case .ready(let m) = s, m.hasProjector { break }
            }
        }
        store.download()
        let end = await waitFor(store) { if case .ready(let m) = $0 { m.hasProjector } else { false } }
        guard case .ready(let model) = end else {
            Issue.record("download did not finish: \(end)")
            return
        }
        watcher.cancel()
        #expect(model.textSource == .downloaded && model.projectorSource == .downloaded)
        #expect(try Data(contentsOf: model.text) == fx.text)
        #expect(try Data(contentsOf: try #require(model.projector)) == fx.projector)
        #expect(!FileManager.default.fileExists(atPath: modelsDir(home).appendingPathComponent("t.gguf.partial").path))
        let reqs = fx.requests
        #expect(reqs.first?.path == "/t.gguf" && reqs.first?.range == "bytes=400-")
        #expect(reqs.contains { $0.path == "/p.gguf" && $0.range == nil })
        #expect(try model.text.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Observers saw the first state, progress that never went backwards, verification and ready.
        let seen = observed.withLock { $0 }
        #expect(seen.first.map { if case .paused = $0 { true } else { false } } == true)
        let received = seen.compactMap { if case .downloading(let p) = $0 { p.receivedBytes } else { nil } }
        #expect(received == received.sorted())
        #expect(seen.contains(.verifying(.text)))
    }

    /// 4. A checksum mismatch deletes the .partial, retries once, then fails with .checksum.
    @Test func checksumMismatchRetriesOnceThenFails() async throws {
        let fx = ModelFixture()
        fx.serve()
        let home = scratch("checksum")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = fx.store(home: home, textSHA: String(repeating: "0", count: 64))
        store.download()
        let end = await waitFor(store) { if case .failed = $0 { true } else { false } }
        guard case .failed(let error, _) = end else {
            Issue.record("expected failure, got \(end)")
            return
        }
        #expect(error == .checksum(.text))
        #expect(fx.requests.filter { $0.path == "/t.gguf" }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: modelsDir(home).appendingPathComponent("t.gguf.partial").path))
        #expect(!FileManager.default.fileExists(atPath: modelsDir(home).appendingPathComponent("t.gguf").path))
    }

    /// 5. Not enough free space: fails before any request with needed = remaining + 512 MB.
    @Test func diskFullBeforeAnyRequest() async throws {
        let fx = ModelFixture()
        fx.serve()
        let home = scratch("disk")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = write(fx.text.prefix(100), modelsDir(home), "t.gguf.partial")
        let store = fx.store(home: home, capacity: { _ in 4_096 })
        store.download()
        let end = await waitFor(store) { if case .failed = $0 { true } else { false } }
        #expect(
            end
                == .failed(
                    .diskFull(needed: fx.total - 100 + ModelStore.headroomBytes, available: 4_096),
                    progress: DownloadProgress(
                        file: .text, receivedBytes: 100, totalBytes: fx.total,
                        bytesPerSecond: nil)))
        #expect(fx.requests.isEmpty)
    }

    /// Offline: the transfer error maps to .failed(.offline) with progress, and the .partial is kept.
    @Test func offlineFailsWithProgress() async throws {
        let fx = ModelFixture()
        fx.serve(failWith: .notConnectedToInternet)
        let home = scratch("offline")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = write(fx.text.prefix(250), modelsDir(home), "t.gguf.partial")
        let store = fx.store(home: home)
        store.download()
        let end = await waitFor(store) { if case .failed = $0 { true } else { false } }
        guard case .failed(.offline, let progress) = end else {
            Issue.record("expected .failed(.offline), got \(end)")
            return
        }
        #expect(progress?.receivedBytes == 250)
        #expect(FileManager.default.fileExists(atPath: modelsDir(home).appendingPathComponent("t.gguf.partial").path))
    }

    /// No network call happens without download().
    @Test func noRequestWithoutDownload() async throws {
        let fx = ModelFixture()
        fx.serve()
        let home = scratch("quiet")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = fx.store(home: home)
        _ = store.resolve()
        _ = await store.verifyCandidates()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fx.requests.isEmpty)
        #expect(store.state == .missing)
    }

    /// cancel() deletes the .partial files and returns to .missing.
    @Test func cancelDeletesPartials() async throws {
        let fx = ModelFixture()
        let home = scratch("cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let partial = write(fx.text.prefix(10), modelsDir(home), "t.gguf.partial")
        let store = fx.store(home: home)
        store.cancel()
        let end = await waitFor(store) { $0 == .missing }
        #expect(end == .missing)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    /// 6. remove() deletes only our own copies, never a dev override.
    @Test func removeNeverTouchesOverride() async throws {
        let fx = ModelFixture()
        let home = scratch("remove")
        defer { try? FileManager.default.removeItem(at: home) }
        let own = write(fx.text, modelsDir(home), "t.gguf")
        let ownP = write(fx.projector, modelsDir(home), "p.gguf")
        let dev = write(fx.text, home, "dev.gguf")
        let store = fx.store(home: home)
        #expect(store.resolve()?.textSource == .downloaded)
        try await store.remove()
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(!FileManager.default.fileExists(atPath: ownP.path))
        #expect(FileManager.default.fileExists(atPath: dev.path))
        #expect(store.state == .missing)
    }

    /// Test builds before 1.0.0 kept the model in Application Support; it moves to ~/.hunch/models once, without a copy.
    @Test func modelsMoveToDotFolder() throws {
        let home = scratch("dot")
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent("Library/Application Support/Hunch/Models")
        let model = write(Data("m".utf8), old, ModelFile.text.fileName)
        let inode = try FileManager.default.attributesOfItem(atPath: model.path)[.systemFileNumber] as? Int
        Paths.migrateModelsToDotFolder(home: home)
        let moved = modelsDir(home).appendingPathComponent(ModelFile.text.fileName)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try FileManager.default.attributesOfItem(atPath: moved.path)[.systemFileNumber] as? Int == inode)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        Paths.migrateModelsToDotFolder(home: home)  // second run: nothing to do
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    /// Test builds before 1.0.0 kept the index in Application Support; it moves to ~/.hunch/index once, without a copy, and a
    /// file already in the new folder is never replaced.
    @Test func indexMovesToDotFolder() throws {
        let home = scratch("dotindex")
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent("Library/Application Support/Hunch")
        let catalog = write(Data("c".utf8), old, "index.sqlite")
        _ = write(Data("w".utf8), old, "index.sqlite-wal")
        let inode = try FileManager.default.attributesOfItem(atPath: catalog.path)[.systemFileNumber] as? Int
        let new = Paths.indexDirectory(home: home)
        _ = write(Data("newer".utf8), new, "vectors.bin")
        _ = write(Data("older".utf8), old, "vectors.bin")
        Paths.migrateIndexToDotFolder(home: home)
        let moved = new.appendingPathComponent("index.sqlite")
        #expect(try FileManager.default.attributesOfItem(atPath: moved.path)[.systemFileNumber] as? Int == inode)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("index.sqlite-wal").path))
        #expect(try Data(contentsOf: new.appendingPathComponent("vectors.bin")) == Data("newer".utf8))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("vectors.bin").path))
        try FileManager.default.removeItem(at: old.appendingPathComponent("vectors.bin"))
        Paths.migrateIndexToDotFolder(home: home)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// importFiles verifies size + SHA and copies into Models/; a wrong file is refused.
    @Test func importVerifiesAndCopies() async throws {
        let fx = ModelFixture()
        let home = scratch("import")
        let src = scratch("import-src")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: src)
        }
        let store = fx.store(home: home)
        var bad = fx.text
        bad[0] ^= 1
        await #expect(throws: ModelStoreError.checksum(.text)) {
            try await store.importFiles([write(bad, src, "bad.gguf")])
        }
        #expect(store.state == .missing)
        let model = try await store.importFiles([write(fx.text, src, "a.gguf"), write(fx.projector, src, "b.gguf")])
        #expect(model.text == modelsDir(home).appendingPathComponent("t.gguf") && model.textSource == .downloaded)
        #expect(model.hasProjector)
        #expect(store.state == .ready(model))
        #expect(store.modelsDirectory == modelsDir(home))
    }

    /// 7. attachModel on a name-only backend: the embedder appears and the status leaves .modelMissing.
    @Test(.enabled(if: EngineEmbedderTests.modelExists)) func attachModelLeavesModelMissing() async throws {
        let dir = scratch("attach")
        let tree = scratch("attach-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        _ = write(Data("x".utf8), tree, "quarterly budget.xlsx")
        let backend = SearchBackend(directory: dir, roots: [tree], modelURL: nil, projectorURL: nil)
        #expect(backend.embedder == nil && backend.indexStatus.phase == .modelMissing)
        backend.start()
        await backend.wait(for: .caughtUp)
        let model = try #require(ModelStore().resolve())
        await backend.attachModel(model)
        #expect(backend.embedder != nil)
        #expect(backend.modelURL == model.text && backend.projectorURL == model.projector)
        #expect(backend.indexStatus.phase != .modelMissing)
        await backend.attachModel(model)  // idempotent
        #expect(backend.modelURL == model.text)
        await backend.coordinator?.stop()
        await backend.content?.stop()
    }
}

@Suite struct LegacyAppSupportTests {
    @Test func movesBetterSpotlightDataOnceAndNeverOverwrites() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hunch-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support")
        let old = support.appendingPathComponent("BetterSpotlight/Models")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: old.appendingPathComponent("m.gguf"))

        Paths.migrateLegacyAppSupport(home: home)
        let moved = support.appendingPathComponent("Hunch/Models/m.gguf")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("BetterSpotlight").path))

        // A second old folder (a reinstalled 1.0.0) never replaces data already under the new name.
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        Paths.migrateLegacyAppSupport(home: home)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(FileManager.default.fileExists(atPath: old.path))
    }
}
