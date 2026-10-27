import AppKit
import Quartz

/// Borderless, non-activating floating panel. Shows and hides instantly (`animationBehavior = .none`): it is opened
/// 100+ times a day. The glass is drawn by SwiftUI inside it (one multi-subpath `glassEffect`), so the window itself
/// is clear, has no shadow and no material of its own.
final class SearchPanel: NSPanel {
    var onResignKey: (() -> Void)?
    /// Quick Look asks the responder chain who controls it.
    weak var quickLook: QuickLookController?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the glass draws its own rim and depth
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Explicit: the 4 pt lanes are fully transparent and must still catch clicks.
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    // Quick Look calls these on the main thread (responder chain of the key window).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if let panel { quickLook?.begin(panel) } }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if let panel { quickLook?.end(panel) } }
    }
}

/// Data source + delegate for `QLPreviewPanel`: previews the slip's file (the file itself, also for OCR hits).
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var url: URL? {
        didSet {
            guard url != oldValue, isVisible else { return }
            QLPreviewPanel.shared()?.reloadData()
        }
    }

    /// Keys pressed inside the Quick Look window (↑/↓ move the slip, Esc/⌘Y close).
    var onKey: ((NSEvent) -> Bool)?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return onKey?(event) ?? false
    }
}
