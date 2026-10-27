import CoreGraphics
import Foundation

/// The two Seam token sets. `.large` only where the slab, its full results area and the 24 pt bottom clearance fit.
enum PanelSize: Sendable, Equatable { case large, compact }

/// Where the slab goes on one screen. Computed once per `show()`; pure, O(1), allocation-free.
struct PanelMetrics: Sendable, Equatable {
    let size: PanelSize
    /// `Theme.large` / `.compact`, with `resultsHeight` reduced on very short screens (never below 4 name rows).
    let theme: Theme
    /// visibleFrame.maxY − slab top edge.
    let topInset: CGFloat
    /// Screen coordinates (AppKit, y up), integral.
    let slabFrame: CGRect
    /// `slabFrame` grown by the shadow margin on every side: the panel window's frame.
    let windowFrame: CGRect
    /// slabFrame.minY − visibleFrame.minY.
    let gapBelow: CGFloat
}

/// v4-spec §1 (layout-v4.py). No AppKit screen queries here: callers pass `ScreenProvider.visibleFrame(for:)`.
enum PanelLayout {
    /// Equal to `SeamRoot.margin` (asserted in `PanelController`).
    static let shadowMargin: CGFloat = 16
    static let topFraction: CGFloat = 0.22
    static let maxTopInset: CGFloat = 320
    static let minTopInset: CGFloat = 72
    /// 16 pt shadow margin + 8, so the shadow never meets the Dock.
    static let bottomClearance: CGFloat = 24

    static func size(for visible: CGRect) -> PanelSize {
        visible.height >= 780 && visible.width >= 1000 ? .large : .compact
    }

    static func metrics(visibleFrame v: CGRect) -> PanelMetrics {
        let size = size(for: v)
        let t = size == .large ? Theme.large : Theme.compact
        var res = t.resultsHeight
        let fixed = t.bandHeight + t.seam
        var top = min((v.height * topFraction).rounded(), maxTopInset)
        var over = top + fixed + res + bottomClearance - v.height
        if over > 0 {
            top = max(minTopInset, top - over)
            over = top + fixed + res + bottomClearance - v.height
        }
        if over > 0 {
            res = max(t.footerHeight + 4 * (t.nameContent + t.seam), res - over)
        }
        let slab = fixed + res
        let slabX = (v.midX - t.slabWidth / 2).rounded()
        let slabTop = v.maxY - top
        let slabFrame = CGRect(x: slabX, y: slabTop - slab, width: t.slabWidth, height: slab)
        return PanelMetrics(
            size: size,
            theme: res == t.resultsHeight ? t : t.with(resultsHeight: res),
            topInset: top,
            slabFrame: slabFrame,
            windowFrame: slabFrame.insetBy(dx: -shadowMargin, dy: -shadowMargin),
            gapBelow: slabFrame.minY - v.minY)
    }
}

/// A fake screen for DEBUG screenshots (`BS_SCREEN=WxH[,dock=bottom|left|right|autohide][,menu=24|37][,docksize=70]`).
/// Pure so the parser and the inset maths are unit-testable; release builds never construct one.
struct FakeScreen: Sendable, Equatable {
    enum Dock: String, Sendable { case bottom, left, right, autohide }
    var width: CGFloat
    var height: CGFloat
    var dock: Dock = .bottom
    var menu: CGFloat = 24
    var dockSize: CGFloat = 70

    /// Notched MacBook Pro/Air default sizes have a 37 pt menu bar.
    private static let notchedWidths: Set<CGFloat> = [1470, 1512, 1710, 1728]

    init(width: CGFloat, height: CGFloat, dock: Dock = .bottom, menu: CGFloat? = nil, dockSize: CGFloat = 70) {
        self.width = width
        self.height = height
        self.dock = dock
        self.menu = menu ?? (Self.notchedWidths.contains(width) ? 37 : 24)
        self.dockSize = dockSize
    }

    init?(spec: String) {
        let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let size = parts.first else { return nil }
        let wh = size.lowercased().split(separator: "x")
        guard wh.count == 2, let w = Double(wh[0]), let h = Double(wh[1]), w > 0, h > 0 else { return nil }
        var dock = Dock.bottom
        var menu: CGFloat?
        var dockSize: CGFloat = 70
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "dock": dock = Dock(rawValue: kv[1]) ?? .bottom
            case "menu": menu = Double(kv[1]).map { CGFloat($0) }
            case "docksize": dockSize = Double(kv[1]).map { CGFloat($0) } ?? 70
            default: break
            }
        }
        self.init(width: w, height: h, dock: dock, menu: menu, dockSize: dockSize)
    }

    /// The fake screen's frame: its top-left corner sits at `anchorTopLeft` (the real visibleFrame's top-left).
    func frame(anchorTopLeft p: CGPoint) -> CGRect {
        CGRect(x: p.x, y: p.y - height, width: width, height: height)
    }

    /// The fake visibleFrame: menu bar off the top, Dock (or the 4 pt auto-hide strip) off its edge.
    func visibleFrame(anchorTopLeft p: CGPoint) -> CGRect {
        var v = frame(anchorTopLeft: p)
        v.size.height -= menu
        switch dock {
        case .bottom: v.origin.y += dockSize; v.size.height -= dockSize
        case .left: v.origin.x += dockSize; v.size.width -= dockSize
        case .right: v.size.width -= dockSize
        case .autohide: v.origin.y += 4; v.size.height -= 4
        }
        return v
    }
}
