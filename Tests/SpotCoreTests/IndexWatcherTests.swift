import CoreServices
import Foundation
import Synchronization
import Testing
@testable import SpotCore

@Suite struct IndexWatcherTests {
    @Test func picksUpCreateRenameDeleteWithin2s() async throws {
        let t = IndexTempDir()
        let watcher = Watcher(roots: [t.url], latency: 0.3)
        let stream = watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let a = t.path + "/a.txt", b = t.path + "/b.txt"
        let t0 = ContinuousClock.now
        t.write("a.txt", "hello")
        try FileManager.default.moveItem(atPath: a, toPath: b)
        try FileManager.default.removeItem(atPath: b)

        let seen = Mutex<(created: Bool, renamed: Bool, removed: Bool, lastID: UInt64)>((false, false, false, 0))
        let collector = Task {
            for await batch in stream {
                let done = seen.withLock { s -> Bool in
                    for e in batch.events {
                        if e.path == a && e.isCreated { s.created = true }
                        if (e.path == a || e.path == b) && e.isRenamed { s.renamed = true }
                        if e.path == b && e.isRemoved { s.removed = true }
                    }
                    s.lastID = max(s.lastID, batch.lastEventID)
                    return s.created && s.renamed && s.removed
                }
                if done { return }
            }
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
        }
        await collector.value
        timeout.cancel()
        let elapsed = ContinuousClock.now - t0
        let s = seen.withLock { $0 }
        #expect(s.created && s.renamed && s.removed, "events seen: \(s)")
        #expect(elapsed < .seconds(2))
        #expect(s.lastID > 0)
        print("Watcher: create+rename+delete observed in \(elapsed)")
    }

    @Test func replaysSinceEventID() async throws {
        let t = IndexTempDir()
        let since = Watcher.currentEventID
        t.write("while-away.txt")
        try await Task.sleep(for: .milliseconds(200))
        let watcher = Watcher(roots: [t.url], latency: 0.1)
        let stream = watcher.start(since: since)
        defer { watcher.stop() }
        let found = Task {
            for await batch in stream where batch.events.contains(where: { $0.path.hasSuffix("/while-away.txt") }) {
                return true
            }
            return false
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
            watcher.stop()
        }
        let ok = await found.value
        timeout.cancel()
        #expect(ok)
    }

    @Test func flagDecoding() {
        let e = FileEvent(path: "/x", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir), id: 1)
        #expect(e.mustScanSubDirs && e.isDirectory && !e.isCreated)
    }
}
