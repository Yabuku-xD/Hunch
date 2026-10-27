import SwiftUI

/// The slab's glass shape: non-overlapping rounded rectangles. The query band; the results above the slip; the
/// slip itself; the results below it. Selecting a row only changes which two 4 pt lanes are cut open, so no row moves.
/// Outer corners use the slab radius, corners at a cut use 6.
struct SeamPath: Shape {
    var width: CGFloat
    var band: CGFloat
    var seam: CGFloat
    var height: CGFloat
    var outer: CGFloat
    var cut: CGFloat
    var hasResults: Bool
    var hasSlip: Bool
    /// Slip edges in slab coordinates (already scrolled).
    var slipTop: CGFloat
    var slipBottom: CGFloat
    /// Width carved off the slip's trailing end for the ⌘K chips.
    var chipCarve: CGFloat
    /// Height of the footer at the slab's bottom (0 when hidden). The slip never cuts into it.
    var footer: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(slipTop, slipBottom), chipCarve) }
        set {
            slipTop = newValue.first.first
            slipBottom = newValue.first.second
            chipCarve = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func add(_ r: CGRect, _ tl: CGFloat, _ tr: CGFloat, _ bl: CGFloat, _ br: CGFloat) {
            guard r.height >= 1, r.width >= 1 else { return }
            let radii = RectangleCornerRadii(topLeading: tl, bottomLeading: bl, bottomTrailing: br, topTrailing: tr)
            path.addPath(UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: r))
        }
        guard hasResults else {
            add(CGRect(x: 0, y: 0, width: width, height: band), outer, outer, outer, outer)
            return path
        }
        add(CGRect(x: 0, y: 0, width: width, height: band), outer, outer, cut, cut)
        let resultsTop = band + seam
        var top = max(slipTop, resultsTop)
        var bottom = min(slipBottom, height - footer)
        guard hasSlip, bottom - top >= 1 else {
            add(CGRect(x: 0, y: resultsTop, width: width, height: height - resultsTop), cut, cut, outer, outer)
            return path
        }
        // Above the slip (absent when the slip's upper cut is the query seam itself).
        let aboveBottom = top - seam
        if aboveBottom - resultsTop >= 1 {
            add(CGRect(x: 0, y: resultsTop, width: width, height: aboveBottom - resultsTop), cut, cut, cut, cut)
        } else {
            top = resultsTop
        }
        // Below the slip; when nothing is left, the slip takes the slab's outer bottom corners.
        let belowTop = bottom + seam
        let reachesBottom = height - belowTop < 1
        if reachesBottom {
            bottom = height
        } else {
            add(CGRect(x: 0, y: belowTop, width: width, height: height - belowTop), cut, cut, outer, outer)
        }
        let bottomRadius = reachesBottom ? outer : cut
        add(CGRect(x: 0, y: top, width: width - chipCarve, height: bottom - top),
            cut, cut, bottomRadius, chipCarve > 0.5 ? cut : bottomRadius)
        return path
    }
}
