import Foundation

/// Research format D for embedding a file/folder/app name (MRR 0.975 vs 0.803 for name-as-title):
/// `title: none | text: {humanized name} ({kind}) in {parent}`.
public enum NameDocument {
    /// The `(title, text)` pair to pass to `Embedder.embedDocuments`. `parent` is shown relative to home when possible.
    public static func make(path: String, kind: ItemKind) -> (title: String, text: String) {
        let url = URL(fileURLWithPath: path)
        let file = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let stem = ext.isEmpty || kind == .folder ? file : String(file.dropLast(ext.count + 1))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parent = url.deletingLastPathComponent().path
        if parent.hasPrefix(home + "/") { parent.removeFirst(home.count + 1) }
        return make(name: stem, kindLabel: label(kind: kind, ext: ext), parent: parent)
    }

    public static func make(name: String, kindLabel: String, parent: String) -> (title: String, text: String) {
        let human = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return ("none", "\(human) (\(kindLabel)) in \(parent)")
    }

    static func label(kind: ItemKind, ext: String) -> String {
        switch kind {
        case .app: return "application"
        case .folder: return "folder"
        case .file:
            switch ext {
            case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp", "bmp", "raw", "dng": return "image"
            case "pdf": return "PDF document"
            case "mov", "mp4", "m4v", "avi", "mkv": return "video"
            case "mp3", "m4a", "wav", "aiff", "flac": return "audio"
            case "doc", "docx", "pages", "rtf", "txt", "md": return "document"
            case "xls", "xlsx", "numbers", "csv": return "spreadsheet"
            case "ppt", "pptx", "key": return "presentation"
            case "zip", "tar", "gz", "dmg", "7z": return "archive"
            case "swift", "py", "js", "ts", "c", "h", "cpp", "rs", "go", "java", "sh": return "source code"
            case "": return "file"
            default: return "\(ext) file"
            }
        }
    }
}
