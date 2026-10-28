import AppKit
import SwiftUI

/// v4 §5: a 560 pt preferences window. `NSTabViewController` (toolbar style), one hosting controller per pane, created
/// on open and released on close. Height = min(pane fitting height, visible height − 40), top edge anchored.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 560
    let model: SettingsModel
    private var window: NSWindow?
    private var tabs: SettingsTabController?

    init(model: SettingsModel) {
        self.model = model
    }

    var isKey: Bool { window?.isKeyWindow ?? false }
    var isVisible: Bool { window?.isVisible ?? false }

    func show(pane: SettingsPane? = nil) {
        model.reload()
        if window == nil { build() }
        guard let window, let tabs else { return }
        let target = pane ?? SettingsPane.restored(from: model.defaults)
        tabs.select(target)
        if !window.isVisible {
            // Centred on the screen under the pointer every time it opens; the user can move it from there.
            tabs.fit(animate: false)
            window.setFrameOrigin(ScreenProvider.centredFrame(size: window.frame.size).origin)
        }
        ActivationPolicy.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
    }

    func select(_ pane: SettingsPane) {
        guard isKey else { return }
        tabs?.select(pane)
    }

    private func build() {
        let tabs = SettingsTabController(model: model)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = DebugOverrides.appearance
        #if DEBUG
        assert(
            !window.styleMask.contains(.miniaturizable) && !window.styleMask.contains(.resizable),
            "Settings must not be miniaturizable or resizable")
        #endif
        self.window = window
        self.tabs = tabs
    }

    func windowWillClose(_ notification: Notification) {
        model.recorder.stop()
        model.stopModelUpdates()
        if let window { ActivationPolicy.windowClosed(window) }
        // Release the pane views (M4: created on open, released on close).
        window?.contentViewController = nil
        window = nil
        tabs = nil
    }
}

/// The toolbar tabs. Crossfade between panes (none under Reduce Motion); the window height follows the pane.
@MainActor
final class SettingsTabController: NSTabViewController {
    private let model: SettingsModel
    private var restoring = true

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        let reduceMotion = DebugOverrides.systemReduceMotion
        transitionOptions = reduceMotion ? [] : [.crossfade, .allowUserInteraction]
        for pane in SettingsPane.allCases {
            let root: AnyView =
                switch pane {
                case .general: AnyView(GeneralPane(model: model))
                case .search: AnyView(SearchPane(model: model))
                case .index: AnyView(IndexPane(model: model))
                case .about: AnyView(AboutPane())
                }
            let hosting = NSHostingController(rootView: root.debugAccessibilityOverrides())
            hosting.sizingOptions = []
            // NSTabViewController propagates the selected child's title to the window; without it the title reads
            // "Untitled" (v4 visual check). §7: the window title is the pane name.
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            addTabViewItem(item)
        }
        restoring = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index } else { applySelection(pane) }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard !restoring, let id = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: id) else {
            return
        }
        applySelection(pane)
    }

    private func applySelection(_ pane: SettingsPane) {
        pane.save(to: model.defaults)
        view.window?.title = pane.title
        fit(animate: !DebugOverrides.systemReduceMotion)
    }

    /// Height = min(pane fitting height, visible height − 40); the Form scrolls past the cap.
    func fit(animate: Bool) {
        guard let window = view.window, let content = tabViewItems[safe: selectedTabViewItemIndex]?.viewController
        else { return }
        let fitting = Self.fittingHeight(content.view)
        let visible =
            window.screen.map { ScreenProvider.visibleFrame(for: $0) }
            ?? ScreenProvider.screenUnderMouse().map { ScreenProvider.visibleFrame(for: $0) } ?? .zero
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let cap = visible.height > 0 ? visible.height - 40 : 800
        let height = min(fitting + titlebar, cap).rounded()
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size = CGSize(width: SettingsWindowController.width, height: height)
        // Top edge anchored, but a taller pane never grows past the bottom of the screen.
        if visible.height > 0, frame.minY < visible.minY { frame.origin.y = visible.minY }
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    /// A grouped Form reports its scroll content's ideal height through `fittingSize`; clamp nonsense values.
    private static func fittingHeight(_ view: NSView) -> CGFloat {
        let h = view.fittingSize.height
        return h.isFinite && h >= 120 && h < 4000 ? h : 520
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
