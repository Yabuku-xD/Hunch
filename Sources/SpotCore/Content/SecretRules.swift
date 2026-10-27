import Foundation

/// K3: files whose *contents* are never read (their names stay searchable), and chunks that are never stored.
public enum SecretRules {
    /// Bumped whenever a rule widens; the pipeline re-checks queued files once per revision.
    static let revision = 2
    static let exactNames: Set<String> = [
        ".env", ".envrc", ".netrc", ".npmrc", ".pypirc", "credentials", ".git-credentials", "_netrc",
    ]
    static let secretExtensions: Set<String> = [
        "env", "pem", "key", "p12", "pfx", "kdbx", "1pif", "agilekeychain", "keychain", "keychain-db", "ppk", "jks",
        "keystore", "asc", "gpg", "pgp",
    ]
    private static let wordPattern = regex("(?i)(password|passwd|secret|credential|token)s?(\\.|$)")
    /// "password-list.txt", "my_passwords 2024.csv", "aws-credentials.json": the unambiguous words as a whole
    /// name part (separators `-_ .`), not only right before the extension. "secret"/"token" stay suffix-only:
    /// "secret-santa.txt" and "token-ring-notes.md" are ordinary documents.
    private static let partPattern = regex("(?i)(^|[-_ .])(passwords?|passwd|credentials?)([-_ .]|$)")
    private static let chunkPattern = regex(
        "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|xox[bp]-[A-Za-z0-9-]{10,}")

    /// Compiles a constant pattern; nil (never expected) disables that rule instead of crashing.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        do { return try NSRegularExpression(pattern: pattern) } catch {
            assertionFailure("SecretRules: bad pattern \(pattern): \(error)")
            return nil
        }
    }

    /// True when `path`'s content must not be indexed.
    public static func isSecret(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        if exactNames.contains(lower) { return true }
        let ext = (lower as NSString).pathExtension
        if secretExtensions.contains(ext) || ext.hasPrefix("keychain") { return true }
        if lower.hasSuffix(".env") || lower.hasPrefix(".env.") { return true }
        // SSH private keys: id_rsa, id_ed25519 … (the .pub halves are fine).
        if lower.hasPrefix("id_") && ext != "pub" { return true }
        let range = NSRange(name.startIndex..., in: name)
        return wordPattern?.firstMatch(in: name, range: range) != nil
            || partPattern?.firstMatch(in: name, range: range) != nil
    }

    /// True when the text holds a private key or a well-known token format.
    public static func containsSecret(_ text: String) -> Bool {
        chunkPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Drops chunks that contain secrets.
    public static func filter(_ chunks: [ExtractedChunk]) -> [ExtractedChunk] {
        chunks.filter { !containsSecret($0.text) }
    }

    /// Extension-less files: read only when they start like text and not like a private key.
    public static func startsLikePrivateKey(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        return head.hasPrefix("-----BEGIN") && head.contains("PRIVATE KEY")
    }

    /// K22 (c): database side files stay name-searchable but never enter the content queue.
    public static func isDatabaseSideFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".sqlite-wal") || lower.hasSuffix(".sqlite-shm") || lower.hasSuffix("-journal")
            || lower.hasSuffix(".db-wal") || lower.hasSuffix(".db-shm")
    }
}
