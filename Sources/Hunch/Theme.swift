import AppKit

/// Every Seam layout number (v2-concepts.md "Typography and spacing"). Views read tokens only. Two sets: the 1440-class
/// screen and the 1280-class screen; `PanelLayout.metrics` picks the set once per show from the target screen's
/// `visibleFrame` and may shorten `resultsHeight` on very short screens.
struct Theme: Equatable, Sendable {
    let slabWidth: CGFloat
    private(set) var resultsHeight: CGFloat
    let bandHeight: CGFloat
    let seam: CGFloat = 4
    let outerRadius: CGFloat
    let cutRadius: CGFloat = 6
    let padding: CGFloat
    let gutter: CGFloat
    /// Leading column: holds the 32/28 pt tile (icon or proof crop, one size for every row), so titles align.
    let leading: CGFloat
    let icon: CGFloat
    let proof: CGFloat
    let iconGap: CGFloat
    let nameContent: CGFloat
    let evidenceContent: CGFloat
    let railContent: CGFloat = 84
    let messageContent: CGFloat = 96
    let titleSize: CGFloat
    let querySize: CGFloat
    let magnifierSize: CGFloat = 17
    let locationSize: CGFloat = 12
    let evidenceSize: CGFloat = 12.5
    let locatorSize: CGFloat = 11.5
    let chipHeight: CGFloat
    /// The quiet footer: the slab's last section (index status left, primary action and ⌘K right).
    let footerHeight: CGFloat
    let footerSize: CGFloat = 11.5
    /// Below 700 pt the kind label column is dropped and the locator takes its place.
    var showsKindColumn: Bool { slabWidth >= 700 }

    var slabHeight: CGFloat { bandHeight + seam + resultsHeight }
    /// x of the leading column's centre: the magnifier sits on it, so glyph and icons share one axis.
    var leadingCentre: CGFloat { padding + gutter + leading / 2 }
    /// x where titles start; the query text starts here too.
    var titleStart: CGFloat { padding + gutter + leading + iconGap }

    static let large = Theme(
        slabWidth: 720, resultsHeight: 456, bandHeight: 52, outerRadius: 22, padding: 12, gutter: 24, leading: 44,
        icon: 32, proof: 32, iconGap: 12, nameContent: 44, evidenceContent: 56, titleSize: 14, querySize: 21,
        chipHeight: 30, footerHeight: 28)

    static let compact = Theme(
        slabWidth: 680, resultsHeight: 392, bandHeight: 48, outerRadius: 20, padding: 10, gutter: 22, leading: 40,
        icon: 28, proof: 28, iconGap: 10, nameContent: 40, evidenceContent: 52, titleSize: 13.5, querySize: 20,
        chipHeight: 28, footerHeight: 26)

    /// The same tokens with a shorter results area (`PanelLayout` step 4).
    func with(resultsHeight: CGFloat) -> Theme {
        var copy = self
        copy.resultsHeight = resultsHeight
        return copy
    }
}
