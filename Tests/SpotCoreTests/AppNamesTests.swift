import Foundation
import Testing
@testable import SpotCore

@Suite struct AppNamesTests {
    static func makeApp(_ dir: URL, _ name: String, info: [String: String], strings: [String: [String: String]] = [:]) throws -> URL {
        let app = dir.appendingPathComponent(name, isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        for (lang, table) in strings {
            let lproj = resources.appendingPathComponent("\(lang).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let text = table.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
            try Data(text.utf8).write(to: lproj.appendingPathComponent("InfoPlist.strings"))
        }
        return app
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("appnames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func emptyDisplayNameFallsBackToBundleName() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try Self.makeApp(dir, "Rock Tool.app", info: ["CFBundleDisplayName": "", "CFBundleName": "Basalt"])
        let item = Item(id: 7, path: app.path, name: "Rock Tool.app", kind: .app, modified: .now)
        #expect(AppNames.keys(for: item, languages: ["en"]) == ["Basalt"])
        let index = NameIndex(aliases: { AppNames.keys(for: $0, languages: ["en"]) })
        index.upsert([item])
        #expect(index.search("basalt", limit: 5).map(\.id) == [7])
    }

    @Test func localizedAndPinyinKeysHitOneRow() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try Self.makeApp(dir, "Terminal.app", info: ["CFBundleName": "Terminal"],
                                   strings: ["zh-Hans": ["CFBundleDisplayName": "终端"]])
        let item = Item(id: 3, path: app.path, name: "Terminal.app", kind: .app, modified: .now)
        let keys = AppNames.keys(for: item, languages: ["zh-Hans-CN"])
        #expect(keys.contains("终端") && keys.contains("zhongduan") && keys.contains("zd"))
        let other = Item(id: 4, path: "/x/zebra dance.txt", name: "zebra dance.txt", kind: .file, modified: .now)
        let index = NameIndex(aliases: { AppNames.keys(for: $0, languages: ["zh-Hans-CN"]) })
        index.replaceAll([item, other])
        for q in ["终端", "zhongduan", "terminal"] {
            #expect(index.search(q, limit: 5).map(\.id) == [3], "\(q)")
        }
        let zd = index.search("zd", limit: 5).map(\.id)
        #expect(zd.first == 3 && zd.filter { $0 == 3 }.count == 1)
        // Aliases follow the item: removing it removes every key.
        index.remove([3])
        #expect(index.search("zhongduan", limit: 5).isEmpty)
    }

    @Test func languageChainAndNorwegian() {
        #expect(AppNames.chain("zh-Hans-CN").prefix(3) == ["zh-Hans-CN", "zh_Hans_CN", "zh-Hans"])
        #expect(AppNames.chain("nb-NO").contains("no"))
    }

    @Test func fullwidthFoldsToASCII() {
        let item = Item(id: 1, path: "/x/a：b.txt", name: "a：b.txt", kind: .file, modified: .now)
        let index = NameIndex(items: [item])
        #expect(index.search("a:b", limit: 5).map(\.id) == [1])
        #expect(index.search("ａ：ｂ", limit: 5).map(\.id) == [1])
    }
}
