import Foundation

/// A published release: what the in-app updater needs from GitHub's `releases/latest` response.
public struct Release: Sendable, Equatable {
    public let version: String
    public let archive: URL
    public let archiveName: String
    public let checksums: URL
    public let page: URL
}

/// Pure parts of the updater, unit-tested: the GitHub response, version order and SHA256SUMS lookup.
public enum UpdateCheck {
    public static let latestAPI = URL(string: "https://api.github.com/repos/Yabuku-xD/Hunch/releases/latest")!

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// The release, or nil when it is a draft or prerelease or lacks the arm64 zip or SHA256SUMS.txt.
    public static func release(from data: Data) throws -> Release? {
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard p.draft != true, p.prerelease != true else { return nil }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        guard components(version) != nil,
            let zip = p.assets.first(where: { $0.name == "Hunch-\(version)-arm64.zip" }),
            let sums = p.assets.first(where: { $0.name == "SHA256SUMS.txt" })
        else { return nil }
        return Release(
            version: version, archive: zip.browser_download_url, archiveName: zip.name,
            checksums: sums.browser_download_url, page: p.html_url)
    }

    /// X.Y.Z only; anything else (\"dev\", suffixes) is not comparable.
    static func components(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    /// True when `candidate` is a later X.Y.Z than `current`. A non-X.Y.Z current version (a dev build) never updates.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        return b.lexicographicallyPrecedes(a)
    }

    /// The lowercase hex SHA-256 listed for `name` in a `shasum -a 256` file.
    public static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let file = fields[1].trimmingCharacters(in: .whitespaces).trimmingPrefix("*")
            let hash = fields[0].lowercased()
            if String(file) == name, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }
}
