import Foundation

/// EmbeddingGemma 2 in a helper process (`hunch-embedder`, next to the app's executable), so that unloading the
/// model returns all of its memory: llama.cpp's vocabulary, Metal buffers and heap fragments go away with the
/// process instead of staying in the app's malloc zones (about 50–110 MB measured in 1.1.0).
///
/// One request at a time over pipes (`EmbedderWire`). A helper that died is relaunched on the next call. Dropping the
/// last reference closes the pipe; the helper exits on end of input.
public actor ProcessEmbedder: Embedder {
    public nonisolated let modelURL: URL
    public nonisolated let dimension: Int
    private nonisolated let helper: URL
    private nonisolated let io = DispatchQueue(label: "hunch.embedder.io")
    private var link: Link?

    /// The running helper and its pipes. Unchecked: its handles are read and written only on the serial `io` queue.
    private final class Link: @unchecked Sendable {
        let process: Process
        let input: FileHandle
        let output: FileHandle

        init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            self.output = output
        }

        deinit {
            try? input.close()
            if process.isRunning { process.terminate() }
        }
    }

    /// The helper inside the app (`Contents/Helpers/Hunch Helper.app`, a background-only bundle so it reads as part of
    /// Hunch), else `hunch-embedder` beside the executable (`swift build` products), else nil (tests without the helper).
    /// `HUNCH_EMBEDDER_IN_PROCESS=1` forces nil.
    public static var helperURL: URL? {
        if ProcessInfo.processInfo.environment["HUNCH_EMBEDDER_IN_PROCESS"] == "1" { return nil }
        guard let exe = Bundle.main.executableURL else { return nil }
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Helpers/Hunch Helper.app/Contents/MacOS/Hunch Helper"),
            exe.deletingLastPathComponent().appendingPathComponent("hunch-embedder"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts the helper and waits until the model is loaded (it fails with the helper's `EmbedderError`).
    public static func launch(helper: URL, modelURL: URL, dimension: Int) async throws -> ProcessEmbedder {
        let e = ProcessEmbedder(helper: helper, modelURL: modelURL, dimension: dimension)
        try await e.connect()
        return e
    }

    private init(helper: URL, modelURL: URL, dimension: Int) {
        self.helper = helper
        self.modelURL = modelURL
        self.dimension = dimension
    }

    public func embedQueries(_ q: [String]) async throws -> [[Float]] {
        try await request(EmbedderWire.encodeQueries(q))
    }

    public func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] {
        try await request(EmbedderWire.encodeDocuments(d))
    }

    private func connect() async throws {
        let (helper, model, dimension) = (self.helper, modelURL, self.dimension)
        link = try await onIO { () throws -> Link in
            let process = Process()
            process.executableURL = helper
            process.arguments = [model.path, String(dimension)]
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.standardError
            do { try process.run() } catch { throw EmbedderError.modelLoadFailed(helper.path) }
            let link = Link(process: process, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
            try EmbedderWire.readHandshake(link.output)
            return link
        }
    }

    private func request(_ body: Data) async throws -> [[Float]] {
        if link == nil || link?.process.isRunning == false {
            link = nil
            try await connect()
        }
        guard let link else { throw EmbedderError.modelLoadFailed(helper.path) }
        do {
            return try await onIO {
                try link.input.write(contentsOf: body)
                return try EmbedderWire.readVectors(link.output)
            }
        } catch let e as EmbedderError {
            throw e
        } catch {
            // The pipe broke: the helper died. Drop it; the next call starts a new one.
            self.link = nil
            throw EmbedderError.decodeFailed(-1)
        }
    }

    private func onIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            io.async { c.resume(with: Result { try body() }) }
        }
    }
}

/// The helper protocol, little-endian. Request: op (u8: 1 queries, 2 documents), count (u32), then per item one
/// string (queries) or two (title, text), each a u32 byte length + UTF-8. Reply: status u8 0 + count u32 + width u32
/// + count×width f32, or status 1 + error. Handshake after load: 0 + model width u32, or 1 + error. Error: code u32,
/// two i32 values, message (u32 length + UTF-8).
public enum EmbedderWire {
    static let opQueries: UInt8 = 1
    static let opDocuments: UInt8 = 2

    public static func encodeQueries(_ q: [String]) -> Data {
        var d = Data([opQueries])
        append(UInt32(q.count), to: &d)
        for s in q { append(s, to: &d) }
        return d
    }

    public static func encodeDocuments(_ docs: [(title: String, text: String)]) -> Data {
        var d = Data([opDocuments])
        append(UInt32(docs.count), to: &d)
        for doc in docs {
            append(doc.title, to: &d)
            append(doc.text, to: &d)
        }
        return d
    }

    /// One request, or nil at end of input.
    public static func readRequest(_ h: FileHandle) throws -> (queries: [String]?, documents: [(String, String)]?)? {
        guard let op = try readExactly(h, 1, eofOK: true)?.first else { return nil }
        let n = Int(try readU32(h))
        switch op {
        case opQueries:
            return (try (0..<n).map { _ in try readString(h) }, nil)
        case opDocuments:
            return (nil, try (0..<n).map { _ in (try readString(h), try readString(h)) })
        default:
            throw EmbedderError.decodeFailed(-2)
        }
    }

    public static func writeHandshake(_ h: FileHandle, width: Int) throws {
        var d = Data([0])
        append(UInt32(width), to: &d)
        try h.write(contentsOf: d)
    }

    public static func writeVectors(_ h: FileHandle, _ v: [[Float]]) throws {
        var d = Data([0])
        append(UInt32(v.count), to: &d)
        append(UInt32(v.first?.count ?? 0), to: &d)
        for row in v { row.withUnsafeBytes { d.append(contentsOf: $0) } }
        try h.write(contentsOf: d)
    }

    public static func writeError(_ h: FileHandle, _ e: EmbedderError) throws {
        let (code, a, b, text): (UInt32, Int32, Int32, String) =
            switch e {
            case .modelMissing(let p): (1, 0, 0, p)
            case .modelLoadFailed(let p): (2, 0, 0, p)
            case .contextFailed: (3, 0, 0, "")
            case .invalidDimension(let r, let m): (4, Int32(r), Int32(m), "")
            case .tokenizeFailed(let t): (5, 0, 0, t)
            case .decodeFailed(let rc): (6, rc, 0, "")
            case .noEmbedding(let s): (7, Int32(s), 0, "")
            }
        var d = Data([1])
        append(code, to: &d)
        append(UInt32(bitPattern: a), to: &d)
        append(UInt32(bitPattern: b), to: &d)
        append(text, to: &d)
        try h.write(contentsOf: d)
    }

    static func readHandshake(_ h: FileHandle) throws {
        guard let status = try readExactly(h, 1)?.first else { throw EmbedderError.contextFailed }
        if status != 0 { throw try readError(h) }
        _ = try readU32(h)
    }

    static func readVectors(_ h: FileHandle) throws -> [[Float]] {
        guard let status = try readExactly(h, 1)?.first else { throw EmbedderError.decodeFailed(-1) }
        if status != 0 { throw try readError(h) }
        let n = Int(try readU32(h))
        let width = Int(try readU32(h))
        guard n > 0 else { return [] }
        guard let bytes = try readExactly(h, n * width * 4) else { throw EmbedderError.decodeFailed(-1) }
        let flat = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (0..<n).map { Array(flat[($0 * width)..<(($0 + 1) * width)]) }
    }

    private static func readError(_ h: FileHandle) throws -> EmbedderError {
        let code = try readU32(h)
        let a = Int32(bitPattern: try readU32(h))
        let b = Int32(bitPattern: try readU32(h))
        let text = try readString(h)
        return switch code {
        case 1: .modelMissing(text)
        case 2: .modelLoadFailed(text)
        case 3: .contextFailed
        case 4: .invalidDimension(requested: Int(a), model: Int(b))
        case 5: .tokenizeFailed(text)
        case 6: .decodeFailed(a)
        default: .noEmbedding(sequence: Int(a))
        }
    }

    private static func append(_ v: UInt32, to d: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }

    private static func append(_ s: String, to d: inout Data) {
        let bytes = Data(s.utf8)
        append(UInt32(bytes.count), to: &d)
        d.append(bytes)
    }

    private static func readU32(_ h: FileHandle) throws -> UInt32 {
        guard let b = try readExactly(h, 4) else { throw EmbedderError.decodeFailed(-1) }
        return b.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    private static func readString(_ h: FileHandle) throws -> String {
        let n = Int(try readU32(h))
        guard n > 0 else { return "" }
        guard let b = try readExactly(h, n) else { throw EmbedderError.decodeFailed(-1) }
        return String(decoding: b, as: UTF8.self)
    }

    /// Exactly `n` bytes; nil on end of input before the first byte when `eofOK`, else an error.
    private static func readExactly(_ h: FileHandle, _ n: Int, eofOK: Bool = false) throws -> Data? {
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            guard let chunk = try h.read(upToCount: n - out.count), !chunk.isEmpty else {
                if out.isEmpty, eofOK { return nil }
                throw EmbedderError.decodeFailed(-1)
            }
            out.append(chunk)
        }
        return out
    }
}
