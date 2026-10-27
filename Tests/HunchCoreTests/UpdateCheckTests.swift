import Foundation
import Testing

@testable import HunchCore

@Suite struct UpdateCheckTests {
    private func payload(tag: String, assets: [String], prerelease: Bool = false) -> Data {
        let list = assets.map {
            "{\"name\":\"\($0)\",\"browser_download_url\":\"https://github.com/Yabuku-xD/Hunch/releases/download/\(tag)/\($0)\"}"
        }
        return Data(
            """
            {"tag_name":"\(tag)","html_url":"https://github.com/Yabuku-xD/Hunch/releases/tag/\(tag)",
             "draft":false,"prerelease":\(prerelease),"assets":[\(list.joined(separator: ","))]}
            """.utf8)
    }

    @Test func parsesTheArchiveAndChecksums() throws {
        let r = try #require(
            try UpdateCheck.release(
                from: payload(
                    tag: "v1.0.1", assets: ["Hunch-1.0.1-arm64.dmg", "Hunch-1.0.1-arm64.zip", "SHA256SUMS.txt"])
            ))
        #expect(r.version == "1.0.1")
        #expect(r.archiveName == "Hunch-1.0.1-arm64.zip")
        #expect(r.checksums.lastPathComponent == "SHA256SUMS.txt")
    }

    @Test func skipsPrereleasesAndIncompleteReleases() throws {
        #expect(
            try UpdateCheck.release(
                from: payload(tag: "v1.0.1", assets: ["Hunch-1.0.1-arm64.zip", "SHA256SUMS.txt"], prerelease: true))
                == nil)
        #expect(try UpdateCheck.release(from: payload(tag: "v1.0.1", assets: ["Hunch-1.0.1-arm64.zip"])) == nil)
        #expect(try UpdateCheck.release(from: payload(tag: "nightly", assets: ["SHA256SUMS.txt"])) == nil)
    }

    @Test func versionOrder() {
        #expect(UpdateCheck.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))
        #expect(UpdateCheck.isNewer("2.0.0", than: "1.99.99"))
        #expect(!UpdateCheck.isNewer("1.0.0", than: "1.0.0"))
        #expect(!UpdateCheck.isNewer("0.9.0", than: "1.0.0"))
        #expect(!UpdateCheck.isNewer("1.0.1", than: "dev"))
        #expect(!UpdateCheck.isNewer("1.0", than: "0.9.0"))
    }

    @Test func checksumLookup() {
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "B", count: 64)
        let sums = "\(a)  Hunch-1.0.1-arm64.zip\n\(b) *Hunch-1.0.1-arm64.dmg\nbad line\n"
        #expect(UpdateCheck.checksum(for: "Hunch-1.0.1-arm64.zip", in: sums) == a)
        #expect(UpdateCheck.checksum(for: "Hunch-1.0.1-arm64.dmg", in: sums) == b.lowercased())
        #expect(UpdateCheck.checksum(for: "other.zip", in: sums) == nil)
    }
}
