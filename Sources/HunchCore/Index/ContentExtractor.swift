import AppKit
import Foundation
import PDFKit

/// Builds the document text for embedding (owner: indexer).
///
/// Names-only items use research format D, which scored best (MRR 0.975):
/// `title: none | text: golden retriever beach (image) in Pictures/Holidays`.
/// Items with extractable content use `title: {file name} | text: {format-D line}. {content}`.
public struct ContentExtractor: Sendable {
    /// Bytes read from plain-text files.
    public var maxTextBytes: Int
    /// Characters of extracted content kept for embedding (the embedder truncates tokens anyway).
    public var maxChars: Int
    /// Home folder; parent paths are shown relative to it (`Pictures/Holidays`).
    public var home: String

    public init(
        maxTextBytes: Int = 4096, maxChars: Int = 1500,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.maxTextBytes = maxTextBytes
        self.maxChars = maxChars
        self.home = home
    }

    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "rst", "org", "tex", "csv", "tsv", "log", "json", "jsonl",
        "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "html", "htm", "css", "scss", "svg",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "java", "kt", "kts", "scala", "py",
        "rb", "php", "pl", "lua", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "sh", "bash",
        "zsh", "fish", "sql", "r", "jl", "dart", "cs", "fs", "ex", "exs", "erl", "hs", "ml", "zig", "nim",
        "gradle", "cmake", "make", "mk", "dockerfile", "proto", "graphql", "ipynb", "srt", "vtt",
    ]
    static let richExtensions: Set<String> = ["rtf", "docx", "doc", "odt", "wordml"]
    static let binaryExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "nef", "dng",
        "psd", "ai", "mov", "mp4", "m4v", "avi", "mkv", "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "app", "dylib", "so", "a", "o",
        "exe", "dll", "bin", "dat", "db", "sqlite", "sqlite3", "ttf", "otf", "woff", "woff2", "class", "jar",
        "pyc", "gguf", "safetensors", "pt", "onnx", "npy", "parquet", "xls", "xlsx", "ppt", "pptx",
    ]

    // MARK: Documents

    /// The (title, text) pair for the embedding document template.
    public func document(for item: Item) -> (title: String, text: String)? {
        let line = describe(item)
        guard item.kind == .file, let content = extractText(at: item.path) else {
            return (title: "none", text: line)
        }
        return (title: item.name, text: line + ". " + content)
    }

    /// Format D: `{humanized name} ({kind}) in {parent relative to home}`.
    public func describe(_ item: Item) -> String {
        let ns = item.name as NSString
        let ext = item.kind == .file ? ns.pathExtension.lowercased() : ""
        let base = ext.isEmpty ? item.name : ns.deletingPathExtension
        let human = Self.humanize(base.isEmpty ? item.name : base)
        let label = Self.kindLabel(kind: item.kind, ext: ext)
        return "\(human) (\(label)) in \(relativeParent(item.path))"
    }

    func relativeParent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == home { return "Home" }
        if parent.hasPrefix(home + "/") { return String(parent.dropFirst(home.count + 1)) }
        return parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
    }

    static func humanize(_ s: String) -> String {
        var out = ""
        for ch in s {
            out.append(ch == "_" || ch == "-" ? " " : ch)
        }
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func kindLabel(kind: ItemKind, ext: String) -> String {
        switch kind {
        case .app: return "application"
        case .setting: return "system setting"
        case .folder: return "folder"
        case .file: break
        }
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw", "dng", "cr2", "nef",
            "svg":
            return "image"
        case "pdf": return "PDF document"
        case "mov", "mp4", "m4v", "avi", "mkv": return "video"
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg": return "audio"
        case "doc", "docx", "pages", "rtf", "rtfd", "odt": return "document"
        case "txt", "text", "md", "markdown": return "text document"
        case "xls", "xlsx", "numbers", "csv", "tsv": return "spreadsheet"
        case "ppt", "pptx", "key": return "presentation"
        case "zip", "gz", "tgz", "7z", "rar", "xz", "bz2": return "archive"
        case "dmg", "iso": return "disk image"
        case "": return "file"
        default:
            return textExtensions.contains(ext) ? "source code" : "\(ext) file"
        }
    }

    // MARK: Extraction

    /// Extracted text, or nil for binaries / unreadable files / empty content.
    public func extractText(at path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let raw: String?
        if ext == "pdf" {
            raw = pdfText(path)
        } else if Self.richExtensions.contains(ext) {
            raw = richText(path)
        } else if Self.binaryExtensions.contains(ext) {
            return nil
        } else {
            raw = plainText(path)
        }
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxChars))
    }

    /// First `maxTextBytes`, accepted only if it has no NUL bytes and decodes as UTF-8
    /// (a multi-byte sequence cut at the end of the buffer is tolerated).
    func plainText(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxTextBytes), !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        if bytes.contains(0) { return nil }
        for trim in 0...min(3, bytes.count - 1) {
            if let s = String(validating: bytes[..<(bytes.count - trim)], as: UTF8.self) { return s }
        }
        return nil
    }

    func pdfText(_ path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        var parts: [String] = []
        for i in 0..<min(2, doc.pageCount) {
            if let s = doc.page(at: i)?.string { parts.append(s) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func richText(_ path: String) -> String? {
        try? NSAttributedString(url: URL(fileURLWithPath: path), options: [:], documentAttributes: nil).string
    }
}
