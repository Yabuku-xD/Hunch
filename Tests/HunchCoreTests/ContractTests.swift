import Foundation
import Testing

@testable import HunchCore

@Test func searchResultIdMatchesItemId() {
    let item = Item(id: 42, path: "/Applications/Safari.app", name: "Safari", kind: .app, modified: .now)
    let result = SearchResult(item: item, score: 1, source: .name)
    #expect(result.id == 42)
    #expect(ItemKind.file.rawValue == 2)
}
