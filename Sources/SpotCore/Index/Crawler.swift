import Darwin
import Foundation
import Synchronization

/// One filesystem entry found by the crawler or the watcher (no id yet; the catalog assigns ids by path).
public struct CrawlEntry: Sendable, Hashable {
    /// Canonical (NFC) path: the catalog key.
    public var path: String
    /// On-disk spelling of the name (display).
    public var name: String
    public var kind: ItemKind
    public var modified: Date
    /// From the same getattrlistbulk call (nil for synthetic entries, e.g. tests).
    public var identity: FileIdentity?
    public var stamp: FileStamp?

    public init(path: String, name: String, kind: ItemKind, modified: Date, identity: FileIdentity? = nil,
                stamp: FileStamp? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.modified = modified
        self.identity = identity
        self.stamp = stamp
    }
}

public struct CrawlStats: Sendable {
    public var count: Int
    public var seconds: Double
    /// Roots and top-level folders that could not be listed (EPERM/EACCES), K21.
    public var unreadable: [String] = []
    public var itemsPerSecond: Double { seconds > 0 ? Double(count) / seconds : 0 }
}

/// Walks roots (home, /Applications, …) producing apps, folders and files (owner: indexer).
///
/// Enumeration uses `getattrlistbulk` (name, object type, mtime, flags per entry, one syscall per
/// buffer) in a bounded task group over second-level directories. Packages are leaves, hidden
/// entries and noise folders are skipped.
public struct Crawler: Sendable {
    public var roots: [URL]
    /// Home folder used for the ~/Library and ~/.Trash exclusions.
    public var home: String
    public var maxConcurrency: Int

    /// Directory extensions treated as leaves (not descended into).
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "aplibrary", "migratedphotolibrary", "fcpbundle", "logicx", "band", "framework", "plugin", "kext",
        "appex", "xpc", "prefpane", "qlgenerator", "mdimporter", "saver", "wdgt", "component", "vst", "vst3",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "dsym", "rtfd", "pages", "numbers", "key",
        "pkg", "mpkg", "sparsebundle", "scptd", "lpdf", "nib", "storyboardc", "xcassets", "docarchive",
        "photosLibrary".lowercased(), "theater", "movpkg", "abbu", "cpgz", "workflow", "action", "safariextz",
    ]

    /// Directory names (lowercased) never descended into, anywhere.
    public static let skippedNames: Set<String> = [
        "node_modules", "deriveddata", "caches", "cache", "__pycache__", "pods", "bower_components",
        ".build", ".git", ".svn", ".hg", ".trash", "trash", "build-cache", "xcuserdata",
        // K22 (a)
        "venv", ".venv", "site-packages", ".tox", ".gradle", ".next", ".nuxt", ".parcel-cache", ".terraform",
    ]

    /// Apps-only shallow roots added next to `/System/Applications` (K8).
    public static let appOnlyRoots = ["/System/Library/CoreServices", "/System/Library/CoreServices/Applications"]

    /// First bytes of a valid CACHEDIR.TAG (bford.info/cachedir).
    static let cacheDirSignature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    static func isValidCacheDirTag(_ dir: String) -> Bool {
        let fd = open(dir + "/CACHEDIR.TAG", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: cacheDirSignature.count)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return n == cacheDirSignature.count && buf == cacheDirSignature
    }

    /// K22 (b) for a directory whose listing showed `.rustc_info.json` / `CACHEDIR.TAG`.
    static func skipsContents(dir: String, sawRustInfo: Bool, sawCacheTag: Bool) -> Bool {
        let base = (dir as NSString).lastPathComponent.lowercased()
        if base == "target" && (sawRustInfo || sawCacheTag) { return true }
        return sawCacheTag && isValidCacheDirTag(dir)
    }

    /// Same rule from the watcher path (no listing at hand): stats the markers.
    static func skipsContents(dir: String) -> Bool {
        let base = (dir as NSString).lastPathComponent.lowercased()
        let hasTag = access(dir + "/CACHEDIR.TAG", F_OK) == 0
        let hasRust = base == "target" && access(dir + "/.rustc_info.json", F_OK) == 0
        return skipsContents(dir: dir, sawRustInfo: hasRust, sawCacheTag: hasTag)
    }

    /// F1: a fresh install indexes apps only, so first launch never touches a TCC-protected folder (Desktop,
    /// Documents, Downloads). The user adds folders in onboarding or Settings; saved settings
    /// (`IndexSettings.metaKey`) still win, so existing installs keep their roots.
    public static var defaultRoots: [URL] { appRoots }

    /// `/Applications`, `/System/Applications` and `~/Applications`.
    public static var appRoots: [URL] { appRoots(home: FileManager.default.homeDirectoryForCurrentUser) }

    static func appRoots(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    public init(roots: [URL] = Crawler.defaultRoots,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.roots = roots
        self.home = Crawler.realPath(home)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Root paths, symlink-resolved (FSEvents reports real paths), NFC, deduplicated and with nested roots removed
    /// unless the outer root's rules would skip them (K19: roots [~, ~/x/.notes] keeps .notes).
    public var rootPaths: [String] {
        let all = Array(Set(roots.map { PathKey.canonical(Crawler.realPath($0.path)) })).sorted()
        return all.filter { r in
            !all.contains { outer in
                outer != r && Crawler.isInside(r, outer)
                    && Crawler.ruleAllows(r, below: outer, home: home)
            }
        }
    }

    /// True when the crawl of `outer` would reach `path` (no hidden/skipped component on the way).
    static func ruleAllows(_ path: String, below outer: String, home: String) -> Bool {
        if Crawler.isInside(path, home + "/Library") || Crawler.isInside(path, home + "/.Trash") { return false }
        var prev = ""
        for comp in path.dropFirst(outer.count + 1).split(separator: "/") {
            if comp.hasPrefix(".") || skippedNames.contains(comp.lowercased()) { return false }
            if comp == "Build" && prev == "Carthage" { return false }
            prev = String(comp)
        }
        return true
    }

    /// Roots strictly inside `root` that are crawled on their own (K19).
    public func nestedRoots(in root: String) -> [String] {
        rootPaths.filter { $0 != root && Crawler.isInside($0, root) }
    }

    // MARK: Crawl

    /// Parallel crawl of all roots.
    public func crawlEntries() async -> (entries: [CrawlEntry], stats: CrawlStats) {
        let t0 = ContinuousClock.now
        var entries: [CrawlEntry] = []
        // Level 0: roots themselves (shallow), then level 1 in parallel, then level-2 subtrees in parallel.
        var level1: [String] = []
        var unreadable: [String] = []
        for root in rootPaths {
            let (found, subdirs) = listDirectory(root)
            if found.isEmpty && subdirs.isEmpty && Crawler.isUnreadable(root) { unreadable.append(root) }
            entries += found
            level1 += subdirs
        }
        if rootPaths.contains("/System/Applications") {
            for extra in Crawler.appOnlyRoots {
                entries += listDirectory(extra).entries.filter { $0.kind == .app }
            }
        }
        var units: [String] = []
        let listed = await parallelMap(level1, { d in (d, listDirectory(d)) })
        for (dir, (found, subdirs)) in listed {
            if found.isEmpty && subdirs.isEmpty && Crawler.isUnreadable(dir) { unreadable.append(dir) }
            entries += found
            units += subdirs
        }
        for found in await parallelMap(units, { walk($0) }) {
            entries += found
        }
        let seconds = (ContinuousClock.now - t0) / .seconds(1)
        return (entries, CrawlStats(count: entries.count, seconds: seconds, unreadable: unreadable.sorted()))
    }

    /// EPERM/EACCES on open (TCC or permissions), K21.
    static func isUnreadable(_ dir: String) -> Bool {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM || errno == EACCES
    }

    /// Synchronous convenience: crawls and numbers items 1…n (ids are normally assigned by the catalog).
    public func crawl() -> [Item] {
        let box = Mutex<[CrawlEntry]>([])
        let roots = rootPaths
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let found = walk(roots[i], includeRoot: false)
            box.withLock { $0 += found }
        }
        return box.withLock { entries in
            entries.enumerated().map { i, e in
                Item(id: UInt32(i + 1), path: e.path, name: e.name, kind: e.kind, modified: e.modified)
            }
        }
    }

    /// Entries for `dir` and everything below it (`dir` itself included when `includeRoot`).
    /// Used by the coordinator to rescan a subtree after MustScanSubDirs or a directory move.
    public func walk(_ dir: String, includeRoot: Bool = false) -> [CrawlEntry] {
        var out: [CrawlEntry] = []
        if includeRoot, let e = Crawler.entry(at: dir) {
            out.append(e)
            guard e.kind == .folder else { return out }
        }
        var stack = [dir]
        while let d = stack.popLast() {
            let (found, subdirs) = listDirectory(d)
            out += found
            stack += subdirs
        }
        return out
    }

    private func parallelMap<T: Sendable>(_ inputs: [String], _ body: @escaping @Sendable (String) -> T) async -> [T] {
        await withTaskGroup(of: T.self) { group in
            var results: [T] = []
            results.reserveCapacity(inputs.count)
            var next = 0
            while next < min(maxConcurrency, inputs.count) {
                let input = inputs[next]
                group.addTask { body(input) }
                next += 1
            }
            while let r = await group.next() {
                results.append(r)
                if next < inputs.count {
                    let input = inputs[next]
                    group.addTask { body(input) }
                    next += 1
                }
            }
            return results
        }
    }

    // MARK: getattrlistbulk

    /// getattrlistbulk with the extended (clone id / ext flags) group; cleared once if the kernel rejects it.
    private static let extendedAttrsSupported = Atomic<Bool>(true)

    /// Lists one directory: indexable children, plus the child directories to descend into.
    /// Each entry carries its `FileIdentity` + `FileStamp` from the same call (I1).
    public func listDirectory(_ dir: String) -> (entries: [CrawlEntry], subdirs: [String]) {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return ([], []) }
        defer { close(fd) }

        var extended = Crawler.extendedAttrsSupported.load(ordering: .relaxed)
        func makeAttrs() -> attrlist {
            var attrs = attrlist()
            attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attrs.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_CHGTIME)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_DOCUMENT_ID)
                | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)
            attrs.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)
            if extended {
                attrs.forkattr = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_CLONEID)
                    | attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_EXT_FLAGS)
            }
            return attrs
        }
        var attrs = makeAttrs()

        let bufSize = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        var entries: [CrawlEntry] = []
        var subdirs: [String] = []
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        let atHome = dir == home
        let inCarthage = (dir as NSString).lastPathComponent == "Carthage"
        var sawRustInfo = false, sawCacheTag = false

        while true {
            // FSOPT_PACK_INV_ATTRS | FSOPT_ATTR_CMN_EXTENDED
            let options: UInt64 = 0x0000_0008 | (extended ? 0x0000_0020 : 0)
            let n = getattrlistbulk(fd, &attrs, buf, bufSize, options)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EINVAL && extended {
                extended = false
                Crawler.extendedAttrsSupported.store(false, ordering: .relaxed)
                attrs = makeAttrs()
                continue
            }
            guard n > 0 else { break }
            var p = buf
            for _ in 0..<n {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                defer { p += length }
                var f = p + 4 + MemoryLayout<attribute_set_t>.size
                let nameOffset = Int(f.loadUnaligned(as: Int32.self))
                let nameLength = Int(f.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                let nameBytes = UnsafeRawBufferPointer(start: f + nameOffset, count: max(0, nameLength - 1))
                f += 8
                let dev = UInt64(UInt32(bitPattern: f.loadUnaligned(as: Int32.self)))
                f += 4
                let objType = f.loadUnaligned(as: UInt32.self)
                f += 4
                let sec = f.loadUnaligned(as: Int.self)
                let nsec = f.loadUnaligned(fromByteOffset: 8, as: Int.self)
                f += 16
                let csec = f.loadUnaligned(as: Int.self)
                let cnsec = f.loadUnaligned(fromByteOffset: 8, as: Int.self)
                f += 16
                let bsdFlags = f.loadUnaligned(as: UInt32.self)
                f += 4
                let docID = f.loadUnaligned(as: UInt32.self)
                f += 4
                let fileID = f.loadUnaligned(as: UInt64.self)
                f += 8
                let dataLength = f.loadUnaligned(as: Int64.self)
                f += 8
                var cloneID: UInt64 = 0, extFlags: UInt64 = 0
                if extended {
                    cloneID = f.loadUnaligned(as: UInt64.self)
                    extFlags = f.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                }

                guard let firstByte = nameBytes.first else { continue }
                if firstByte == UInt8(ascii: ".") {
                    if nameBytes.elementsEqual(".rustc_info.json".utf8) { sawRustInfo = true }
                    continue
                }
                if nameBytes.elementsEqual("CACHEDIR.TAG".utf8) { sawCacheTag = true }
                if bsdFlags & UInt32(UF_HIDDEN) != 0 { continue }
                if nameBytes.contains(0x0D) { continue }  // "Icon\r"
                let name = String(decoding: nameBytes, as: UTF8.self)
                let path = prefix + PathKey.canonical(name)
                let modified = Date(timeIntervalSince1970: Double(sec) + Double(nsec) / 1e9)
                let isDir = objType == UInt32(VDIR.rawValue)
                let identity = FileIdentity(device: dev, fileID: fileID, documentID: docID == 0 ? nil : docID,
                                            cloneID: cloneID == 0 ? nil : cloneID)
                let stamp = FileStamp(size: isDir ? 0 : dataLength, mtimeNs: Int64(sec) * 1_000_000_000 + Int64(nsec),
                                      ctimeNs: Int64(csec) * 1_000_000_000 + Int64(cnsec), flags: bsdFlags,
                                      extFlags: extFlags)

                if isDir {
                    if atHome && (name == "Library" || name == ".Trash") { continue }
                    if Crawler.skippedNames.contains(name.lowercased()) { continue }
                    if inCarthage && name == "Build" { continue }
                    var entry = Crawler.makeEntry(path: path, name: name, isDirectory: true, modified: modified)
                    entry.identity = identity
                    entry.stamp = stamp
                    entries.append(entry)
                    if entry.kind == .folder { subdirs.append(path) }
                    if entry.kind == .app { entries += nestedApps(in: path) }
                } else if objType == UInt32(VREG.rawValue) || objType == UInt32(VLNK.rawValue) {
                    var entry = Crawler.makeEntry(path: path, name: name, isDirectory: false, modified: modified)
                    entry.identity = identity
                    entry.stamp = stamp
                    entries.append(entry)
                }
            }
        }
        if (sawRustInfo || sawCacheTag)
            && Crawler.skipsContents(dir: dir, sawRustInfo: sawRustInfo, sawCacheTag: sawCacheTag) {
            return ([], [])
        }
        return (entries, subdirs)
    }

    /// K8: apps bundled inside an app (`Contents/Applications`, `Contents/Developer/Applications`), depth ≤ 2.
    func nestedApps(in app: String, depth: Int = 0) -> [CrawlEntry] {
        guard depth < 2 else { return [] }
        var out: [CrawlEntry] = []
        for sub in ["/Contents/Applications", "/Contents/Developer/Applications"] {
            let dir = app + sub
            guard access(dir, F_OK) == 0 else { continue }
            for e in listDirectory(dir).entries where e.kind == .app {
                out.append(e)  // listDirectory already expanded e's own nested apps
            }
        }
        // listDirectory already expanded depth-0 children; drop duplicates.
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    // MARK: Path rules (shared with the watcher path)

    static func makeEntry(path: String, name: String, isDirectory: Bool, modified: Date) -> CrawlEntry {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "app" {
            return CrawlEntry(path: path, name: (name as NSString).deletingPathExtension, kind: .app, modified: modified)
        }
        if isDirectory && !packageExtensions.contains(ext) {
            return CrawlEntry(path: path, name: name, kind: .folder, modified: modified)
        }
        return CrawlEntry(path: path, name: name, kind: .file, modified: modified)
    }

    /// lstat-based entry for a single path (nil if it no longer exists).
    public static func entry(at path: String) -> CrawlEntry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        var e = makeEntry(path: PathKey.canonical(path), name: (path as NSString).lastPathComponent, isDirectory: isDir,
                          modified: modified)
        e.identity = FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), fileID: UInt64(st.st_ino))
        e.stamp = FileStamp(size: isDir ? 0 : Int64(st.st_size),
                            mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
                            ctimeNs: Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec),
                            flags: st.st_flags)
        return e
    }

    /// Maps a changed path to the path that should be (re)indexed, or nil if it is outside the
    /// index scope (hidden, skipped folder, ~/Library, outside every root). A path inside a package
    /// maps to the package itself.
    public func indexablePath(for path: String) -> String? {
        indexablePath(for: path, roots: rootPaths)
    }

    /// `rootPaths` precomputed (hot path for event batches).
    public func indexablePath(for rawPath: String, roots: [String]) -> String? {
        let path = PathKey.canonical(rawPath)
        // Deepest root wins (nested roots, K19): skip rules apply below each root only.
        guard let root = roots.filter({ Crawler.isInside(path, $0) }).max(by: { $0.count < $1.count }),
              path != root else { return nil }
        if !Crawler.isInside(root, home + "/Library") {
            if Crawler.isInside(path, home + "/Library") || Crawler.isInside(path, home + "/.Trash") { return nil }
        }
        let comps = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
        var current = root
        var prev = ""
        var i = 0
        while i < comps.count {
            let comp = comps[i]
            if comp.hasPrefix(".") || comp.contains("\r") || Crawler.skippedNames.contains(comp.lowercased()) {
                return nil
            }
            if comp == "Build" && prev == "Carthage" { return nil }
            if i < comps.count - 1, Crawler.skipsContents(dir: current + "/" + comp) { return nil }
            current += "/" + comp
            prev = String(comp)
            let ext = (comp as NSString).pathExtension.lowercased()
            if !ext.isEmpty && Crawler.packageExtensions.contains(ext) {
                // K8: a change inside Host.app/Contents/(Developer/)Applications/Child.app maps to Child.
                if ext == "app" {
                    let rest = comps[(i + 1)...].map(String.init)
                    for lead in [["Contents", "Applications"], ["Contents", "Developer", "Applications"]]
                    where rest.count > lead.count && Array(rest.prefix(lead.count)) == lead
                        && rest[lead.count].lowercased().hasSuffix(".app") {
                        current += "/" + lead.joined(separator: "/")
                        i += lead.count + 1
                        current += "/" + rest[lead.count]
                        prev = rest[lead.count]
                        return current
                    }
                }
                return current
            }
            i += 1
        }
        return current
    }

    static func isInside(_ path: String, _ dir: String) -> Bool {
        path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }
}
