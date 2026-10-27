import Darwin
import Foundation
import Testing
@testable import SpotCore

// v3 plan regression tests: K1 (content runtime), K2 (dataless), K3 (secrets), K5 (Unicode), K6 (catalog ranges).

private func scratch(_ tag: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("V3Tests-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ dir: URL, _ name: String, _ text: String) -> String {
    let p = dir.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: p, contents: Data(text.utf8))
    return p
}

// MARK: K1

@Suite struct SearchBackendTests {
    @Test func testContentAttachedOnStart() async throws {
        let dir = scratch("k1"), tree = scratch("k1-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        write(tree, "a.txt", "zebra quokka")
        let backend = SearchBackend(directory: dir, roots: [tree], modelURL: nil)
        backend.start()
        await backend.wait(for: .contentIdle)
        let content = try #require(backend.content, "start() must build and attach the content runtime")
        let hits = content.fullText.search("quokka", limit: 5)
        let path = hits.first.flatMap { backend.catalog?.item($0.item)?.path }
        #expect(path.map { ($0 as NSString).lastPathComponent } == "a.txt")
        await backend.coordinator?.stop()
        await content.stop()
    }
}

// MARK: K2

@Suite struct DatalessPolicyTests {
    @Test func datalessFlagParsedFromStamp() {
        let placeholder = FileStamp(size: 10, mtimeNs: 0, ctimeNs: 0, flags: FileStamp.datalessFlag)
        let local = FileStamp(size: 10, mtimeNs: 0, ctimeNs: 0, flags: 0)
        #expect(placeholder.isDataless)
        #expect(!local.isDataless)
    }

    @Test func processNeverMaterializesPlaceholders() {
        #expect(Dataless.applyProcessPolicy())
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES (3), process scope (0) → IOPOL_MATERIALIZE_DATALESS_FILES_OFF (1).
        #expect(getiopolicy_np(3, 0) == 1)
    }

    @Test func edeadlkMeansWaitingDownloadNotFailure() {
        #expect(Dataless.isDatalessError(EDEADLK))
        #expect(!Dataless.isDatalessError(EACCES))
        #expect(ContentQueue.State.waitingDownload.rawValue == 3)
    }
}

// MARK: K3

@Suite struct SecretRulesTests {
    @Test func secretFilesAreNameOnly() {
        for name in ["prod.env", ".env", "id_ed25519", "credentials", "passwords.txt", "server.pem", "vault.kdbx"] {
            #expect(ContentReader.tier(for: "/x/" + name) == nil, "\(name) must not be content-indexed")
        }
        for name in ["id_ed25519.pub", "notes.txt", "tokenizer.py"] {
            #expect(ContentReader.tier(for: "/x/" + name) != nil, "\(name) should be content-indexed")
        }
    }

    @Test func secretNamesStaySearchable() {
        let names = NameIndex()
        names.replaceAll([Item(id: 1, path: "/x/passwords.txt", name: "passwords.txt", kind: .file, modified: .now)])
        #expect(names.search("passwords", limit: 5).map(\.id) == [1])
    }

    @Test func chunkWithPrivateKeyIsNeverStored() async throws {
        let dir = scratch("k3"), tree = scratch("k3-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        let p = write(tree, "notes.txt", "pelican notes\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n")
        let ok = write(tree, "plain.txt", "pelican harbor")
        let rt = try ContentRuntime(directory: dir, embedder: nil, vectors: nil, modelURL: nil, policy: .always,
                                    home: tree.path)
        await rt.pipeline.enqueue([Item(id: 1, path: p, name: "notes.txt", kind: .file, modified: .now),
                                   Item(id: 2, path: ok, name: "plain.txt", kind: .file, modified: .now)])
        #expect(await rt.pipeline.waitUntilIdle(timeout: .seconds(20)))
        #expect(rt.fullText.search("pelican", limit: 5).map(\.item) == [2])
        await rt.stop()
    }
}

// MARK: K5

@Suite struct UnicodeTests {
    @Test func nfdAndNfcFindEachOther() async throws {
        let dir = scratch("k5"), tree = scratch("k5-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        let nfc = "사업자", nfd = "사업자".decomposedStringWithCanonicalMapping
        #expect(nfc.unicodeScalars.count != nfd.unicodeScalars.count)
        write(tree, nfd + ".txt", "x")
        let backend = SearchBackend(directory: dir, roots: [tree], modelURL: nil)
        backend.start()
        await backend.wait(for: .caughtUp)
        #expect(backend.nameIndex.search(nfc, limit: 5).count == 1)
        #expect(backend.nameIndex.search(nfd, limit: 5).count == 1)
        let before = backend.catalog?.count ?? 0
        let ids = Set(((try? backend.catalog?.all()) ?? []).map(\.id))
        _ = await backend.verifyIndex()  // second crawl of the same tree: no duplicate rows, ids stable
        #expect(backend.catalog?.count == before)
        #expect(Set(((try? backend.catalog?.all()) ?? []).map(\.id)) == ids)
        #expect(PathKey.canonical(nfd) == nfc)
        await backend.coordinator?.stop()
        await backend.content?.stop()
    }
}

// MARK: K6

@Suite struct CatalogRangeTests {
    @Test func rangeQueriesTouchOnlyTheSubtree() throws {
        let dir = scratch("k6")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog(url: dir.appendingPathComponent("index.sqlite"))
        var items: [Item] = []
        for i in 0..<5_000 {
            items.append(Item(id: 0, path: "/a/other/f\(i).txt", name: "f\(i).txt", kind: .file, modified: .now))
        }
        items.append(Item(id: 0, path: "/a/b", name: "b", kind: .folder, modified: .now))
        for i in 0..<10 { items.append(Item(id: 0, path: "/a/b/x\(i).txt", name: "x\(i).txt", kind: .file, modified: .now)) }
        items.append(Item(id: 0, path: "/a/b c", name: "b c", kind: .folder, modified: .now))
        items.append(Item(id: 0, path: "/a/b c/y.txt", name: "y.txt", kind: .file, modified: .now))
        items.append(Item(id: 0, path: "/a/b.txt", name: "b.txt", kind: .file, modified: .now))
        try catalog.upsert(items)

        let under = try catalog.items(under: "/a/b")
        #expect(under.count == 11)
        #expect(under.allSatisfy { $0.path == "/a/b" || $0.path.hasPrefix("/a/b/") })

        let total = catalog.count
        let removed = try catalog.deleteSubtree(["/a/b"])
        #expect(removed.count == 11)
        #expect(catalog.count == total - 11)
        #expect(try catalog.item(path: "/a/b c/y.txt") != nil)
        #expect(try catalog.item(path: "/a/b.txt") != nil)
        #expect(try catalog.items(under: "/a/b c").count == 2)
    }
}
