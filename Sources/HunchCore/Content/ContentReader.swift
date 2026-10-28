import AppKit
import CoreGraphics
import Foundation
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Routes a file to its extractor and returns text chunks with locations, plus image vectors when a
/// `MediaEmbedder` is available (owner: media). Never throws: corrupt files come back `.unreadable`.
public struct ContentReader: Sendable {
    /// Per-file text read budget: larger text files index their first 64 MB.
    public static let maxTextBytes = 64 << 20
    /// Note on a result that was skipped because the file is a cloud-only placeholder.
    public static let datalessNote = "waitingDownload"
    /// A PDF page with fewer non-space characters than this in its text layer counts as scanned.
    public static let scannedPageChars = 40
    /// Scanned pages OCR'd per PDF.
    public static let maxScannedPages = 300

    public var media: (any ImageEmbedding)?
    public var locale: Locale

    public init(media: (any ImageEmbedding)? = nil, locale: Locale = .current) {
        self.media = media
        self.locale = locale
    }

    // MARK: Classification

    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "mkd", "rst", "org", "adoc", "tex", "bib", "csv", "tsv", "log",
        "json", "jsonl", "ndjson", "geojson", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "xml", "typ",
        "plist", "css", "scss", "sass", "less", "swift", "m", "mm", "h", "hh", "hpp", "c", "cc", "cpp", "cxx", "rs",
        "go", "java", "kt", "kts", "scala", "groovy", "py", "pyi", "rb", "php", "pl", "pm", "lua", "js", "mjs", "cjs",
        "ts", "tsx", "jsx", "vue", "svelte", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "r", "jl", "dart",
        "cs", "fs", "vb", "ex", "exs", "erl", "hrl", "hs", "ml", "mli", "zig", "nim", "clj", "cljs", "el", "lisp",
        "scm", "gradle", "cmake", "make", "mk", "dockerfile", "proto", "graphql", "gql", "ipynb", "srt", "vtt", "ass",
        "sub", "lrc", "nfo", "diff", "patch", "tf", "hcl", "nix", "vim", "asm", "s", "v", "sv", "vhd", "f90", "pas",
        "d", "cue", "csl", "ris", "eml", "mbox", "vcf", "ics", "opml", "rss", "atom", "gpx", "kml", "strings",
        "xliff", "po", "pot", "glsl", "metal", "hlsl", "wgsl", "svg",
    ]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "shtml", "mhtml"]
    static let richExtensions: Set<String> = ["rtf", "doc", "wordml", "webarchive"]
    static let iworkExtensions: Set<String> = ["pages", "key", "numbers"]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "hif", "avif", "tif", "tiff", "webp", "gif", "bmp", "jp2", "jxl",
        "ico", "icns", "tga", "psd", "dng", "raw", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2",
        "raf", "pef", "srw", "erf", "3fr", "iiq", "x3f",
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "qt", "3gp", "3g2", "mts", "m2ts", "ts", "avi",
        "mkv", "webm", "mpg", "mpeg",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac",
        "alac", "ogg", "opus", "amr", "au", "snd",
    ]
    /// Never worth opening.
    static let binaryExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "dmg", "iso", "pkg", "app", "dylib", "so", "a", "o", "exe",
        "dll", "bin", "dat", "db", "sqlite", "sqlite3", "ttf", "otf", "ttc", "woff", "woff2", "class", "jar", "pyc",
        "gguf", "safetensors", "pt", "pth", "onnx", "npy", "npz", "parquet", "arrow", "xls", "ppt", "mdb", "lock",
        "keychain", "keychain-db", "p12", "pfx", "cer", "der", "pem", "key-db", "kdbx", "sparsebundle", "vmdk", "qcow2",
    ]

    /// The tier that reads `path`'s content, or nil when it's names-only.
    public static func tier(for path: String) -> ContentTier? {
        if SecretRules.isSecret(path: path) || SecretRules.isDatabaseSideFile(path) { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        // .ts/.mts are TypeScript or MPEG-TS; decide by content (0x47 sync byte every 188 bytes ⇒ video).
        if ext == "m4p" || ext == "aax" { return nil }  // K20: protected assets, never readable
        if ext == "ts" || ext == "mts" { return isMPEGTransportStream(path) ? .media : .documents }
        if ext == "pdf" || textExtensions.contains(ext) || htmlExtensions.contains(ext) || richExtensions.contains(ext)
            || OfficeReader.extensions.contains(ext)
        {
            return .documents
        }
        if imageExtensions.contains(ext) || iworkExtensions.contains(ext) { return .images }
        if videoExtensions.contains(ext) || audioExtensions.contains(ext) { return .media }
        if binaryExtensions.contains(ext) { return nil }
        if let type = UTType(filenameExtension: ext), !ext.isEmpty {
            if type.conforms(to: .pdf) || type.conforms(to: .text) { return .documents }
            if type.conforms(to: .image) { return .images }
            if type.conforms(to: .audiovisualContent) { return .media }
            if type.conforms(to: .archive) || type.conforms(to: .executable) || type.isDeclared { return nil }
        }
        // No or unknown extension (README, Makefile, .bashrc): sniffed as text in tier 1.
        return .documents
    }

    // MARK: Reading

    /// First 4 KB look like an MPEG transport stream (sync byte 0x47 at every 188-byte packet start).
    static func isMPEGTransportStream(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), head.count >= 188 * 3 else { return false }
        return stride(from: 0, to: head.count, by: 188).allSatisfy { head[head.startIndex + $0] == 0x47 }
    }

    /// Extracts `path` for `tier`. `pages` limits a tier-2 PDF pass to those (scanned) pages.
    /// Dataless placeholders are never read: `.waitingDownload` comes back as `.unreadable` with that note.
    public func read(path: String, tier: ContentTier, pages: [Int]? = nil) async -> ExtractedContent {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failed(.unreadable) }
        if st.st_flags & FileStamp.datalessFlag != 0 { return .failed(.unreadable, Self.datalessNote) }
        if SecretRules.isSecret(path: path) { return .failed(.unsupported, "secret") }
        FileAccessCounter.shared.add(opens: 1, extractions: 1)
        let isDir = ObjCBool((st.st_mode & S_IFMT) == S_IFDIR)
        if isDir.boolValue, !Self.iworkExtensions.contains(ext) { return .failed(.unsupported) }
        switch tier {
        case .names:
            return .failed(.unsupported)
        case .documents:
            if ext == "pdf" { return pdfText(url) }
            if OfficeReader.extensions.contains(ext) {
                guard let chunks = OfficeReader.chunks(url: url, ext: ext) else { return .failed(.unreadable) }
                return ExtractedContent(chunks: chunks)
            }
            if Self.richExtensions.contains(ext) { return richText(url, ext: ext) }
            return plainText(url, html: Self.htmlExtensions.contains(ext))
        case .images:
            if ext == "pdf" { return await pdfScans(url, pages: pages ?? []) }
            if Self.iworkExtensions.contains(ext) { return await iworkPreview(url) }
            return await image(url)
        case .media:
            return await audioVisual(url)
        }
    }

    // MARK: Tier 1

    func plainText(_ url: URL, html: Bool) -> ExtractedContent {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int
        else { return .failed(.unreadable) }
        guard size > 0 else { return .failed(.unsupported) }
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return Dataless.isDatalessError(errno) ? .failed(.unreadable, Self.datalessNote) : .failed(.unreadable)
        }
        // Budget: the first 64 MB of a larger text file (appended tails are handled by the chunk cache).
        let data = mapped.count > Self.maxTextBytes ? mapped.prefix(Self.maxTextBytes) : mapped
        FileAccessCounter.shared.add(bytesRead: Int64(data.count))
        if url.pathExtension.isEmpty && SecretRules.startsLikePrivateKey(data) {
            return .failed(.unsupported, "secret")
        }
        guard var text = TextDecoder.decode(data) else { return .failed(.unsupported) }
        if html { text = MarkupStripper.strip(text) }
        return ExtractedContent(chunks: TextChunker.chunks(text, lines: !html))
    }

    func richText(_ url: URL, ext: String) -> ExtractedContent {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
            size > Self.maxTextBytes
        {
            return .failed(.tooLarge)
        }
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "rtf": opts[.documentType] = NSAttributedString.DocumentType.rtf
        case "doc": opts[.documentType] = NSAttributedString.DocumentType.docFormat
        case "wordml": opts[.documentType] = NSAttributedString.DocumentType.wordML
        case "webarchive": opts[.documentType] = NSAttributedString.DocumentType.webArchive
        default: break
        }
        guard let s = try? NSAttributedString(url: url, options: opts, documentAttributes: nil).string,
            !s.isEmpty
        else { return .failed(.unreadable) }
        return ExtractedContent(chunks: TextChunker.chunks(s))
    }

    func pdfText(_ url: URL) -> ExtractedContent {
        guard let doc = PDFDocument(url: url) else { return .failed(.unreadable) }
        if doc.isLocked { return .failed(.unreadable, "locked") }
        var chunks: [ExtractedChunk] = []
        var scanned: [Int] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = page.string ?? ""
            if text.unicodeScalars.lazy.filter({ !CharacterSet.whitespacesAndNewlines.contains($0) }).count
                < Self.scannedPageChars
            {
                if scanned.count < Self.maxScannedPages { scanned.append(i + 1) }
            }
            chunks += TextChunker.chunks(text, base: ContentLocation(page: i + 1), lines: false)
        }
        return ExtractedContent(chunks: chunks, scannedPages: scanned)
    }

    // MARK: Tier 2

    func pdfScans(_ url: URL, pages: [Int]) async -> ExtractedContent {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return .failed(.unreadable) }
        var chunks: [ExtractedChunk] = []
        for p in pages where p >= 1 && p <= doc.pageCount {
            if Task.isCancelled { break }
            guard let page = doc.page(at: p - 1), let img = Self.render(page) else { continue }
            chunks += TextRecognizer.chunks(await TextRecognizer.recognize(img), base: ContentLocation(page: p))
        }
        return ExtractedContent(chunks: chunks)
    }

    /// A PDF page drawn on white at ≤ 1,600 px on the long side.
    static func render(_ page: PDFPage, maxSide: Double = Double(ImageLoader.maxSide)) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let rotated = page.rotation % 180 != 0
        let (bw, bh) = rotated ? (box.height, box.width) : (box.width, box.height)
        let scale = min(4, maxSide / max(bw, bh))
        let w = Int(bw * scale), h = Int(bh * scale)
        guard w > 0, h > 0,
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    func image(_ url: URL) async -> ExtractedContent {
        let img: CGImage
        switch ImageLoader.load(url) {
        case .success(let i): img = i
        case .failure(.tooLarge): return .failed(.tooLarge)
        case .failure: return .failed(.unreadable)
        }
        return await ocrAndEmbed(img, base: .whole)
    }

    /// OCR text chunks plus (when the model is loaded) one image vector for `img`.
    func ocrAndEmbed(_ img: CGImage, base: ContentLocation, embed: Bool = true) async -> ExtractedContent {
        let lines = await TextRecognizer.recognize(img)
        let chunks = TextRecognizer.chunks(lines, base: base)
        var images: [ExtractedImageVector] = []
        if embed, let media, let rgb = ImageLoader.rgb(img), let v = try? await media.embedImage(rgb) {
            let caption = lines.isEmpty ? nil : String(lines.map(\.text).joined(separator: " ").prefix(160))
            images.append(ExtractedImageVector(location: base, caption: caption, vector: v))
        }
        return ExtractedContent(chunks: chunks, images: images)
    }

    /// Pages/Keynote/Numbers: the package's embedded preview (or a QuickLook thumbnail), OCR'd.
    func iworkPreview(_ url: URL) async -> ExtractedContent {
        let names = ["preview.jpg", "QuickLook/Thumbnail.jpg", "preview-web.jpg", "preview-micro.jpg"]
        var data: Data?
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            data = names.lazy.compactMap { try? Data(contentsOf: url.appendingPathComponent($0)) }.first
        } else if let zip = ZipReader(url: url) {
            data = names.lazy.compactMap { zip.read($0) }.first
        }
        var img = data.flatMap { ImageLoader.load(data: $0) }
        if img == nil { img = await Self.quickLookThumbnail(url) }
        guard let img else { return .failed(.unreadable) }
        return await ocrAndEmbed(img, base: .whole)
    }

    static func quickLookThumbnail(_ url: URL) async -> CGImage? {
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 1600, height: 1600), scale: 1,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).cgImage
    }

    // MARK: Tier 3

    func audioVisual(_ url: URL) async -> ExtractedContent {
        guard let info = await MediaReader.probe(url) else { return .failed(.unreadable) }
        guard info.duration <= MediaReader.maxDuration else { return .failed(.tooLarge) }
        guard info.hasVideo || info.hasAudio else { return .failed(.unsupported) }
        var out = ExtractedContent()
        if info.hasVideo {
            var lastText = ""
            await MediaReader.distinctFrames(url, duration: info.duration) { frame in
                if ImageLoader.isFlat(frame.image) { return }
                let r = await ocrAndEmbed(frame.image, base: ContentLocation(time: frame.time))
                let text = r.chunks.map(\.text).joined(separator: "\n")
                if text != lastText { out.chunks += r.chunks }
                lastText = text
                out.images += r.images
            }
        }
        if info.hasAudio {
            switch await MediaReader.transcribe(url, locale: locale) {
            case .success(let chunks): out.chunks += chunks
            case .failure(.unavailable(let why)):
                out.note = why
                if !info.hasVideo { out.status = .speechUnavailable }
            case .failure(.unreadable):
                if !info.hasVideo { out.status = .unreadable }
            }
        }
        return out
    }
}
