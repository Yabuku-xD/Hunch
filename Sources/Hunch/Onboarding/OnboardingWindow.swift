import AppKit
import SwiftUI

/// The Welcome Guide window (v4 §4): 560 × min(580, visible height − 72), centred on the screen under the mouse.
/// 580, not the spec's 460: at 460 the step 1 example rows and the step 3 folder list were cut off under the footer
/// on every screen (v4 visual check). Shorter screens still scroll the step body over the fixed footer.
/// Created on open and released on close. Esc and ⌘. are Set Up Later.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 560
    private var window: GuideWindow?
    private var model: OnboardingModel?
    private let makeModel: (_ reopened: Bool, _ step: Int?) -> OnboardingModel

    init(makeModel: @escaping (_ reopened: Bool, _ step: Int?) -> OnboardingModel) {
        self.makeModel = makeModel
    }

    var isOpen: Bool { window != nil }

    /// `reopened`: from a menu or Settings (starts at step 1 with current values). `step`: jump to a step (step 4 from
    /// the model-missing status; DEBUG `HUNCH_ONBOARDING_STEP`).
    func show(reopened: Bool, step: Int? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = makeModel(reopened, step)
        model.onClose = { [weak self] in self?.window?.close() }
        let visible = ScreenProvider.screenUnderMouse().map { ScreenProvider.visibleFrame(for: $0) }
        let height = min(580, (visible?.height ?? 900) - 72)
        let window = GuideWindow(
            contentRect: CGRect(x: 0, y: 0, width: Self.width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(AppInfo.name)"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = DebugOverrides.appearance
        window.onCancel = { [weak model] in model?.setUpLater() }
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: Self.width, height: height))
        window.setFrameOrigin(ScreenProvider.centredFrame(size: window.frame.size).origin)
        window.delegate = self
        self.window = window
        self.model = model
        model.start()
        HotKey.shared.interceptor = { [weak self] in
            guard let self, let model = self.model else { return false }
            return model.hotKeyPressed(isKey: self.window?.isKeyWindow ?? false)
        }
        ActivationPolicy.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // The close button is Set Up Later too (the step is kept, `completed` is not set).
        if let model, !model.flow.completed { model.flow.setUpLater(model.defaults) }
        model?.stop()
        HotKey.shared.interceptor = nil
        if let window { ActivationPolicy.windowClosed(window) }
        window?.contentViewController = nil
        window = nil
        model = nil
    }
}

/// Esc and ⌘. both arrive as `cancelOperation:`.
final class GuideWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
