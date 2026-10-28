import CoreServices
import Foundation
import Synchronization

/// One FSEvents file-level event.
public struct FileEvent: Sendable, Hashable {
    public var path: String
    public var flags: UInt32
    public var id: UInt64

    public init(path: String, flags: UInt32, id: UInt64) {
        self.path = path
        self.flags = flags
        self.id = id
    }

    private func has(_ f: Int) -> Bool { flags & UInt32(f) != 0 }
    /// The kernel/daemon coalesced or dropped events below `path`: rescan that subtree.
    public var mustScanSubDirs: Bool {
        !isHistoryDone
            && (has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
                || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagRootChanged))
    }
    public var isCreated: Bool { has(kFSEventStreamEventFlagItemCreated) }
    public var isRemoved: Bool { has(kFSEventStreamEventFlagItemRemoved) }
    public var isRenamed: Bool { has(kFSEventStreamEventFlagItemRenamed) }
    public var isModified: Bool { has(kFSEventStreamEventFlagItemModified) }
    public var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
    public var isHistoryDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
    /// Event ids wrapped: the journal can't be trusted, verify everything.
    public var idsWrapped: Bool { has(kFSEventStreamEventFlagEventIdsWrapped) }
}

/// A coalesced delivery from FSEvents (≈ every `latency` seconds while things change).
public struct ChangeBatch: Sendable {
    public var events: [FileEvent]
    /// Persist this; pass it back as `since` on relaunch to replay what happened while not running.
    public var lastEventID: UInt64

    public init(events: [FileEvent], lastEventID: UInt64) {
        self.events = events
        self.lastEventID = lastEventID
    }
}

/// FSEvents watcher feeding incremental updates (owner: indexer).
///
/// Kernel-side exclusion paths (`FSEventStreamSetExclusionPaths`, ≤ 8: ~/Library, ~/.Trash, caches …),
/// adaptive latency (0.25 s panel visible / 0.5 s hidden; `setLatency` restarts the stream from the last delivered
/// id, so nothing is lost), NFC paths, and `HistoryDone` passed through so the coordinator can leave
/// `.catchingUp`.
public final class Watcher: Sendable {
    public let roots: [URL]
    public let exclusions: [String]
    public var latency: Double { config.withLock { $0.latency } }

    final class Sink: Sendable {
        let continuation: AsyncStream<ChangeBatch>.Continuation
        let lastID = Atomic<UInt64>(0)
        init(_ c: AsyncStream<ChangeBatch>.Continuation) { continuation = c }
    }

    private struct Running: @unchecked Sendable {
        let stream: FSEventStreamRef
        let sink: Sink
    }

    private let running = Mutex<Running?>(nil)
    private let config: Mutex<(latency: Double, unused: Int)>
    private let queue = DispatchQueue(label: "Hunch.Watcher", qos: .utility)

    public init(roots: [URL] = [], latency: Double = 0.3, exclusions: [String]? = nil) {
        self.roots = roots
        self.config = Mutex((latency, 0))
        self.exclusions = exclusions ?? Watcher.defaultExclusions(roots: Crawler(roots: roots).rootPaths)
    }

    deinit { stop() }

    /// ≤ 8 kernel-side exclusions inside the watched roots (FSEvents' limit).
    public static func defaultExclusions(
        roots: [String],
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        let candidates = [
            home + "/Library", home + "/.Trash", home + "/Library/Caches", home + "/.cache",
            home + "/.npm", home + "/.cargo/registry", home + "/.gradle", home + "/.cocoapods",
        ]
        return Array(
            candidates.filter { c in
                roots.contains { Crawler.isInside(c, $0) && c != $0 } && !roots.contains { Crawler.isInside($0, c) }
            }.prefix(8))
    }

    /// The newest event id system-wide; capture before a full crawl and persist it so the watcher
    /// can replay anything that changed during or after the crawl.
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Starts watching. `since` = persisted last event id (nil → only new events).
    /// Restarting finishes the previous stream.
    @discardableResult
    public func start(since: UInt64? = nil) -> AsyncStream<ChangeBatch> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: ChangeBatch.self, bufferingPolicy: .unbounded)
        let sink = Sink(continuation)
        guard let ref = makeStream(sink: sink, since: since) else {
            continuation.finish()
            return stream
        }
        running.withLock { $0 = Running(stream: ref, sink: sink) }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    /// Changes the coalescing latency; the stream restarts from the last delivered event id.
    public func setLatency(_ latency: Double) {
        config.withLock { $0.latency = latency }
        guard
            let r = running.withLock({ s -> Running? in
                defer { s = nil }; return s
            })
        else { return }
        FSEventStreamStop(r.stream)
        FSEventStreamInvalidate(r.stream)
        FSEventStreamRelease(r.stream)
        let last = r.sink.lastID.load(ordering: .relaxed)
        if let ref = makeStream(sink: r.sink, since: last > 0 ? last : nil) {
            running.withLock { $0 = Running(stream: ref, sink: r.sink) }
        } else {
            r.sink.continuation.finish()
        }
    }

    private func makeStream(sink: Sink, since: UInt64?) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(sink).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<Sink>.fromOpaque(info).release() }
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            var events: [FileEvent] = []
            events.reserveCapacity(count)
            var last: UInt64 = 0
            for i in 0..<count {
                let id = rawIDs[i]
                last = max(last, id)
                guard let path = paths[i] as? String else { continue }
                events.append(FileEvent(path: PathKey.canonical(path), flags: rawFlags[i], id: id))
            }
            if last > sink.lastID.load(ordering: .relaxed) { sink.lastID.store(last, ordering: .relaxed) }
            sink.continuation.yield(ChangeBatch(events: events, lastEventID: last))
        }

        let paths = Crawler(roots: roots).rootPaths as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let sinceWhen = since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let ref = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths, sinceWhen, latency, flags)
        else {
            Unmanaged.passUnretained(sink).release()
            return nil
        }
        if !exclusions.isEmpty { FSEventStreamSetExclusionPaths(ref, exclusions as CFArray) }
        FSEventStreamSetDispatchQueue(ref, queue)
        FSEventStreamStart(ref)
        return ref
    }

    public func stop() {
        guard
            let r = running.withLock({ s -> Running? in
                defer { s = nil }; return s
            })
        else { return }
        FSEventStreamStop(r.stream)
        FSEventStreamInvalidate(r.stream)
        FSEventStreamRelease(r.stream)
        r.sink.continuation.finish()
    }
}
