import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Who a file *is*, independent of its path: survives renames and moves on the same volume (v3 plan §B.1).
public struct FileIdentity: Sendable, Hashable {
    public var device: UInt64
    public var fileID: UInt64
    /// APFS document id (survives safe-save replace), when the volume tracks one.
    public var documentID: UInt32?
    /// APFS clone family id. A hint only: equal clone ids alone never prove equal bytes (§B rule 2).
    public var cloneID: UInt64?

    public init(device: UInt64, fileID: UInt64, documentID: UInt32? = nil, cloneID: UInt64? = nil) {
        self.device = device
        self.fileID = fileID
        self.documentID = documentID
        self.cloneID = cloneID
    }
}

/// What a file version looks like, from the same getattrlistbulk call that lists it (no extra syscalls).
public struct FileStamp: Sendable, Hashable {
    public var size: Int64
    public var mtimeNs: Int64
    public var ctimeNs: Int64
    public var flags: UInt32
    /// `ATTR_CMNEXT_EXT_FLAGS` (EF_SHARES_ALL_BLOCKS …), 0 when unknown.
    public var extFlags: UInt64

    public init(size: Int64, mtimeNs: Int64, ctimeNs: Int64, flags: UInt32, extFlags: UInt64 = 0) {
        self.size = size
        self.mtimeNs = mtimeNs
        self.ctimeNs = ctimeNs
        self.flags = flags
        self.extFlags = extFlags
    }

    /// `SF_DATALESS`: an iCloud/File Provider placeholder whose bytes are not on disk.
    public static let datalessFlag: UInt32 = 0x4000_0000
    public var isDataless: Bool { flags & Self.datalessFlag != 0 }
    /// `EF_SHARES_ALL_BLOCKS`: every block of the file is shared with its clone family.
    public static let sharesAllBlocks: UInt64 = 0x0000_0080
    public var sharesAllBlocks: Bool { extFlags & Self.sharesAllBlocks != 0 }
}

/// Full SHA-256 of a file's bytes (Merkle root over 1 MiB block hashes, so appends can extend it).
public struct ContentHash: Sendable, Hashable {
    public let bytes: Data

    public init(bytes: Data) { self.bytes = bytes }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    public static let blockSize = 1 << 20

    /// Merkle root of `blockHashes` (a single-block file hashes to SHA-256(SHA-256(block))).
    public static func root(_ blockHashes: [Data]) -> ContentHash {
        var h = SHA256()
        for b in blockHashes { h.update(data: b) }
        return ContentHash(bytes: Data(h.finalize()))
    }

    /// Streams `path` once (`F_NOCACHE`) and returns the hash plus the bytes hashed, or nil if unreadable.
    /// Never materializes a dataless file: the process runs with materialization off (`Dataless.applyProcessPolicy`).
    public static func of(path: String, blocks: inout [Data]) -> (hash: ContentHash, bytes: Int64)? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buf.deallocate() }
        var total: Int64 = 0
        blocks.removeAll(keepingCapacity: true)
        while true {
            var filled = 0
            while filled < blockSize {
                let n = read(fd, buf + filled, blockSize - filled)
                if n < 0 { if errno == EINTR { continue }; return nil }
                if n == 0 { break }
                filled += n
            }
            if filled == 0 { break }
            blocks.append(Data(SHA256.hash(data: UnsafeRawBufferPointer(start: buf, count: filled))))
            total += Int64(filled)
            FileAccessCounter.shared.add(bytesHashed: Int64(filled))
            if filled < blockSize { break }
        }
        return (root(blocks), total)
    }

    public static func of(path: String) -> ContentHash? {
        var blocks: [Data] = []
        return of(path: path, blocks: &blocks)?.hash
    }
}

/// Canonical (NFC) spelling for every path/name key (K5): HFS+/NFD names and NFC queries meet in one form.
public enum PathKey {
    public static func canonical(_ s: String) -> String {
        // Fast path: pure ASCII is already canonical.
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return s }
        return s.precomposedStringWithCanonicalMapping
    }
}

/// K2: never download iCloud/File Provider placeholders. Process-wide, set once.
public enum Dataless {
    private static let applied: Bool = {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3, IOPOL_SCOPE_PROCESS = 0, IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1
        setiopolicy_np(3, 0, 1) == 0
    }()

    /// Turns dataless materialization off for this process (idempotent). Reads of a placeholder then fail with
    /// EDEADLK instead of downloading it.
    @discardableResult
    public static func applyProcessPolicy() -> Bool { applied }

    /// True when a read failed because the file is a placeholder.
    public static func isDatalessError(_ code: Int32) -> Bool { code == EDEADLK }
}

/// DEBUG/bench hook: counts content reads and hashed bytes (§C "files re-read", "bytes hashed").
public final class FileAccessCounter: Sendable {
    public static let shared = FileAccessCounter()
    private let state = Mutex<(opens: Int, bytesRead: Int64, bytesHashed: Int64, extractions: Int, hashChecks: Int)>(
        (0, 0, 0, 0, 0))

    public struct Snapshot: Sendable, Equatable {
        public var opens: Int, bytesRead: Int64, bytesHashed: Int64, extractions: Int, hashChecks: Int
    }

    public func add(
        opens: Int = 0, bytesRead: Int64 = 0, bytesHashed: Int64 = 0, extractions: Int = 0,
        hashChecks: Int = 0
    ) {
        state.withLock {
            $0.opens += opens
            $0.bytesRead += bytesRead
            $0.bytesHashed += bytesHashed
            $0.extractions += extractions
            $0.hashChecks += hashChecks
        }
    }

    public var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                opens: $0.opens, bytesRead: $0.bytesRead, bytesHashed: $0.bytesHashed,
                extractions: $0.extractions, hashChecks: $0.hashChecks)
        }
    }
}
