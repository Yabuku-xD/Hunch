import AppKit
import Carbon.HIToolbox
import HunchCore
import SwiftUI

/// The screen geometry every window uses: the real `visibleFrame`, or the DEBUG `HUNCH_SCREEN` fake (v4 §6).
@MainActor
enum ScreenProvider {
    /// The display under the mouse (the panel, onboarding and Settings open there).
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    static func visibleFrame(for screen: NSScreen) -> CGRect {
        #if DEBUG
        if let fake = DebugOverrides.screen {
            let real = screen.visibleFrame
            return fake.visibleFrame(anchorTopLeft: CGPoint(x: real.minX, y: real.maxY))
        }
        #endif
        return screen.visibleFrame
    }

    /// Centres a window of `size` on the (possibly fake) visible frame under the mouse.
    static func centredFrame(size: CGSize) -> CGRect {
        guard let screen = screenUnderMouse() else { return CGRect(origin: .zero, size: size) }
        let v = visibleFrame(for: screen)
        return CGRect(
            x: (v.midX - size.width / 2).rounded(), y: (v.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
    }

    #if DEBUG
    private static var outline: NSWindow?
    private static var dockStrip: NSWindow?

    /// `HUNCH_SCREEN_OUTLINE=1`: a 1 pt red frame at the fake screen and a 70 pt grey Dock strip, below the panel.
    static func showOutline(on screen: NSScreen) {
        guard DebugOverrides.screenOutline, let fake = DebugOverrides.screen, outline == nil else { return }
        let real = screen.visibleFrame
        let anchor = CGPoint(x: real.minX, y: real.maxY)
        let frame = fake.frame(anchorTopLeft: anchor)
        func make(_ rect: CGRect, _ configure: (NSView) -> Void) -> NSWindow {
            let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .floating
            w.hasShadow = false
            let v = NSView(frame: CGRect(origin: .zero, size: rect.size))
            v.wantsLayer = true
            configure(v)
            w.contentView = v
            w.orderFrontRegardless()
            return w
        }
        outline = make(frame) { v in
            v.layer?.borderColor = NSColor.systemRed.cgColor
            v.layer?.borderWidth = 1
        }
        let vis = fake.visibleFrame(anchorTopLeft: anchor)
        let strip: CGRect =
            switch fake.dock {
            case .bottom: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: fake.dockSize)
            case .left: CGRect(x: frame.minX, y: frame.minY, width: fake.dockSize, height: vis.height)
            case .right: CGRect(x: frame.maxX - fake.dockSize, y: frame.minY, width: fake.dockSize, height: vis.height)
            case .autohide: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 4)
            }
        dockStrip = make(strip) { v in v.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.35).cgColor }
    }
    #endif
}

/// Shows/hides the panel instantly, positions it per screen, owns the keyboard model and runs actions.
@MainActor
final class PanelController {
    let model: SearchModel
    let admin: IndexAdmin?
    private let panel = SearchPanel()
    private let quickLook = QuickLookController()
    private var hosting: NSHostingView<SeamRoot>?
    private var slabTop: CGFloat = 0
    private var originX: CGFloat = 0
    private var isHiding = false
    private var monitors: [Any] = []
    private var restoreTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// A drag out of the list: the row under the pointer at mouse-down and where it went down.
    private var dragStart: (result: SearchResult, point: NSPoint)?
    private let dragSource = ResultDragSource()
    /// Apps a Quit was sent to that had not quit 3 s later; their chips offer Force Quit instead.
    private var stalledQuits: Set<pid_t> = []
    /// Opens Settings (⌘, and clicks on the band status).
    var onSettings: ((SettingsPane?) -> Void)?
    /// The model-missing status: onboarding step 4, or Settings › Index once onboarding is complete (U11).
    var onModelSetup: (() -> Void)?

    init(engine: any SearchEngine, admin: IndexAdmin?) {
        model = SearchModel(engine: engine)
        self.admin = admin
        panel.quickLook = quickLook
        let hosting = NSHostingView(rootView: SeamRoot(model: model, controller: self))
        hosting.sizingOptions = []  // the panel sizes itself from the model
        panel.contentView = hosting
        self.hosting = hosting
        panel.onResignKey = { [weak self] in self?.resignedKey() }
        model.onHeightChange = { [weak self] in self?.resize() }
        quickLook.onKey = { [weak self] event in self?.handleQuickLookKey(event) ?? false }

        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                if !handled {
                    // After the field editor has processed the key: track IME composition (names-only, prompt hidden).
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncComposing() } }
                }
                return handled ? nil : event
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                let window = event.window
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, window === self.panel else { return false }
                    self.model.scroll(by: delta)
                    return true
                }
                return handled ? nil : event
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    self?.model.setCommandHeld(mods == .command && event.window === self?.panel)
                    self?.applyAlternates(option: mods.contains(.option))
                }
                return event
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
                [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleDrag(event) ?? false }
                return handled ? nil : event
            } as Any)

        if let admin {
            let stream = admin.statusUpdates()
            statusTask = Task { [weak self] in
                for await status in stream {
                    guard let self else { return }
                    self.model.status.update(status, tiers: admin.contentTiers())
                }
            }
            // P8: re-run the visible query when the index changes under it, once the user has been idle ≥ 1 s;
            // `refresh()` keeps the selected id.
            let changes = admin.changes()
            changesTask = Task { [weak self] in
                for await _ in changes {
                    guard let self else { return }
                    self.staleResults = true
                    self.refreshIfIdle()
                }
            }
        }
        _ = RunningApps.shared
        observeScreenChanges()
        assert(PanelLayout.shadowMargin == SeamRoot.margin, "PanelLayout.shadowMargin must equal SeamRoot.margin")
        #if DEBUG
        Measure.shared.view = hosting
        #endif
    }

    // MARK: Visibility

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        switch HotkeyToggle.action(isVisible: panel.isVisible, isKey: panel.isKeyWindow) {
        case .hide: hide()
        case .show: show()
        }
    }

    /// The SwiftUI field's NSTextField (found once; the hosting view never rebuilds the band).
    private weak var field: NSTextField?

    /// P1/P12: the field editor is first responder synchronously, so the first typed key (and an IME's first
    /// composition) never lands before SwiftUI's async focus update.
    func focusField() {
        if field == nil, let hosting { field = Self.findField(in: hosting) }
        guard let field else { return }
        if (panel.firstResponder as? NSTextView)?.delegate === field { return }
        panel.makeFirstResponder(field)
        // makeFirstResponder selects all; put the caret at the end instead (restore selects all on its own).
        if let editor = panel.firstResponder as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    private static func findField(in view: NSView) -> NSTextField? {
        if let f = view as? NSTextField, f.isEditable { return f }
        for sub in view.subviews { if let f = findField(in: sub) { return f } }
        return nil
    }

    private func syncComposing() {
        let editor = panel.firstResponder as? NSTextView
        model.setComposing(editor?.hasMarkedText() ?? false)
    }

    func show() {
        let screen = ScreenProvider.screenUnderMouse()
        place(on: screen)
        let restoring = restoreTask != nil && !model.query.isEmpty
        restoreTask?.cancel()
        restoreTask = nil
        if !restoring, model.isEmptyQuery { model.refresh() }  // favorites/recents may have changed
        resize()
        let wasVisible = panel.isVisible
        hideToken &+= 1  // a deferred orderOut from a previous hide must not hide this show
        panel.makeKeyAndOrderFront(nil)
        focusField()
        #if DEBUG
        assert(field == nil || panel.firstResponder is NSTextView, "field editor must be first responder after show()")
        #endif
        model.didShow()
        if restoring { model.didRestore() }
        #if DEBUG
        Measure.shared.panelShown()
        #endif
        if !wasVisible { admin?.setPanelVisible(true) }
    }

    /// v4 §1: one O(1) `PanelLayout.metrics` per show (and per screen-parameter change while visible).
    private func place(on screen: NSScreen?) {
        guard let screen else { return }
        let m = PanelLayout.metrics(visibleFrame: ScreenProvider.visibleFrame(for: screen))
        if model.theme != m.theme { model.theme = m.theme; model.refresh() }
        if model.displayScale != screen.backingScaleFactor { model.displayScale = screen.backingScaleFactor }
        DisplayScale.current = screen.backingScaleFactor
        if let admin, model.rootsCount != admin.userRootsCount { model.rootsCount = admin.userRootsCount }
        originX = m.slabFrame.minX
        slabTop = m.slabFrame.maxY
        #if DEBUG
        if !layoutLogged || ProcessInfo.processInfo.environment["HUNCH_LAYOUT_LOG"] == "1" {
            layoutLogged = true
            Measure.emit(
                "panel_layout size=\(m.size) top=\(Int(m.topInset)) res=\(Int(m.theme.resultsHeight)) "
                    + "slab=\(Int(m.slabFrame.minX)),\(Int(m.slabFrame.minY)),\(Int(m.slabFrame.width))x\(Int(m.slabFrame.height))"
            )
        }
        ScreenProvider.showOutline(on: screen)
        #endif
    }

    #if DEBUG
    private var layoutLogged = false
    #endif

    /// Dock moved, display added/removed: re-place a visible panel once. Registered once; no polling.
    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.place(on: self.panel.screen ?? ScreenProvider.screenUnderMouse())
                self.resize()
            }
        }
    }

    /// Builds and lays out the SwiftUI graph once while the panel is still ordered out, so the first hotkey press
    /// after launch only positions it and orders it front (the cold build otherwise lands on that first show).
    func prewarm() {
        model.refresh()
        resize()
        hosting?.layoutSubtreeIfNeeded()
        if let hosting { field = Self.findField(in: hosting) }
        // U11: run one throwaway name query so the engine's fold tables, buckets and the row types are warm before
        // the first real keystroke; then return to the root state.
        model.prewarmQuery()
        hosting?.layoutSubtreeIfNeeded()
    }

    private var hideToken = 0

    /// `deferOrderOut`: P4 — after ↵/Esc the window leaves one run-loop turn later, so an input method that is still
    /// finishing its event (Pinyin, Kotoeri) never talks to a window that just disappeared (spin reports).
    func hide(deferOrderOut: Bool = false) {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        quickLook.close()
        model.closeChips()
        if deferOrderOut {
            hideToken &+= 1
            let token = hideToken
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hideToken == token else { return }
                    self.panel.orderOut(nil)
                }
            }
        } else {
            panel.orderOut(nil)
        }
        model.status.panelDidHide()
        isHiding = false
        admin?.setPanelVisible(false)
        // Query and selection survive 60 s; reopening restores them fully selected. After that, start fresh
        // (while hidden, so the next show never paints a stale frame).
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, !self.panel.isVisible else { return }
            self.restoreTask = nil
            self.model.reset()
        }
    }

    private func resignedKey() {
        // Quick Look and the Open With chooser keep the panel up; anything else hides it.
        if quickLook.isVisible { return }
        hide()
    }

    /// The window is the slab plus a margin for the glass rim; it only changes between band-only and full height.
    func resize() {
        let height = model.panelHeight
        let m = SeamRoot.margin
        let frame = NSRect(
            x: originX - m, y: slabTop - height - m,
            width: model.theme.slabWidth + 2 * m, height: height + 2 * m)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    func selectAllInField() {
        (panel.firstResponder as? NSTextView)?.selectAll(nil)
    }

    #if DEBUG
    var hostingForDebug: NSView? { hosting }

    /// `--measure`: one real keyDown through the app's event path (local monitors → field editor → binding), so the
    /// sample includes exactly what a typed character costs, including the text system's own insert.
    func typeForMeasurement(_ character: String) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)
        else { return }
        NSApp.sendEvent(event)
    }
    #endif

    func statusClicked() {
        hide()
        switch model.status.route {
        case .modelSetup: onModelSetup?()
        case .settingsIndex: onSettings?(.index)
        }
    }

    func openSettings(_ pane: SettingsPane) {
        hide()
        onSettings?(pane)
    }

    // MARK: Clicks

    func click(_ row: Row) {
        if model.selectedID == row.id {
            activate()
        } else {
            model.click(row.id)
            syncQuickLook()
        }
    }

    func clickRail(_ index: Int) {
        let wasFocused = model.selectedID == .rail && model.railIndex == index
        model.clickRail(index)
        if wasFocused { activate() }
    }

    // MARK: Actions

    /// ↵: the primary action of the slip.
    func activate() {
        guard let row = model.selectedRow else { return }
        switch row.content {
        case .finder(let query):
            searchInFinder(query)
        case .showAll(let group, _):
            model.expand(group)
        default:
            guard let result = model.selectedResult else { return }
            open(result)
        }
    }

    private func open(_ result: SearchResult, with app: URL? = nil) {
        let item = result.item
        guard FileManager.default.fileExists(atPath: item.path) else {
            // The row stays until the next replacement; the panel stays open.
            model.setSlipHint("No longer exists")
            return
        }
        let url = URL(fileURLWithPath: item.path)
        quickLook.close()
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let failure: @Sendable (Error?) -> Void = { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.openFailed(result, error) }
            }
            if item.kind == .app, app == nil {
                // P3: openApplication also reopens a running app that has no windows (activate() alone does not),
                // and works from a fullscreen Space.
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, e in failure(e) }
            } else if let app {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, e in
                    failure(e)
                }
            } else {
                // PDF page hits: no public, PDFKit-free way to ask the default app for a page; plain open.
                NSWorkspace.shared.open(url, configuration: configuration) { _, e in failure(e) }
            }
        }
        admin?.recordOpen(item)
        hide(deferOrderOut: true)
    }

    private func openFailed(_ result: SearchResult, _ error: Error) {
        NSLog("Hunch: open failed: %@", String(describing: error))
        show()
        model.setSlipHint("Couldn't open it")
        let chips = PanelAction.chips(
            for: result, isPinned: admin?.isPinned(result.item) ?? false,
            isRunning: RunningApps.shared.isRunning(result.item.path))
        model.openChips(chips, focus: chips.firstIndex(of: .openWith) ?? 0)
    }

    private func searchInFinder(_ query: String) {
        NSWorkspace.shared.showSearchResults(forQueryString: query.trimmingCharacters(in: .whitespaces))
        hide()
    }

    private func reveal(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.item.path)])
        admin?.recordOpen(result.item)
        hide()
    }

    private func copyPath(_ result: SearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.item.path, forType: .string)
        model.status.flash("Path copied")
    }

    private func copyText(_ result: SearchResult) {
        guard let snippet = result.match?.snippet else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        model.status.flash("Text copied")
    }

    private func togglePin(_ result: SearchResult) {
        guard let admin else { return }
        if admin.isPinned(result.item) {
            admin.unpin(result.item)
            model.status.flash("Unpinned")
        } else {
            admin.pin(result.item)
            model.status.flash("Pinned")
            AppDefaults.store.set(true, forKey: "hint.pin.seen")
        }
        if model.isEmptyQuery { model.refresh() }
    }

    private func quitApp(_ result: SearchResult) {
        guard let app = RunningApps.shared.application(at: result.item.path) else { return }
        app.terminate()  // never forced; unsaved documents get their normal prompt
        let name = DisplayText.name(result.item)
        model.status.flash("Quitting \(name)…")
        // One check, no polling: an app still running 3 s later is waiting on a dialog or hung. Offer Force Quit.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !app.isTerminated else { return }
            self.stalledQuits.insert(app.processIdentifier)
            self.model.status.flash("\(name) has not quit · ⌃⌥⇧Q to Force Quit")
            if let chips = self.model.chips, !chips.isChooser {
                self.model.replaceChips(chips.actions.map { $0 == .quit ? .forceQuit : $0 })
            }
        }
    }

    private func forceQuitApp(_ result: SearchResult) {
        guard let app = RunningApps.shared.application(at: result.item.path) else { return }
        let name = DisplayText.name(result.item)
        stalledQuits.remove(app.processIdentifier)
        model.status.flash(app.forceTerminate() ? "Force quit \(name)" : "Could not force quit \(name)")
    }

    private func copyFile(_ result: SearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([URL(fileURLWithPath: result.item.path) as NSURL])
        model.status.flash("File copied")
    }

    private func quitStalled(_ result: SearchResult) -> Bool {
        guard !stalledQuits.isEmpty, let app = RunningApps.shared.application(at: result.item.path) else {
            return false
        }
        return stalledQuits.contains(app.processIdentifier)
    }

    /// ⌥ pressed or released: chips with an alternate show it (Quit → Force Quit, Copy Path → Copy File).
    private func applyAlternates(option: Bool) {
        guard let state = model.chips, !state.isChooser else { return }
        model.replaceChips(PanelAction.swapped(state.actions, option: option))
    }

    /// Drags a result row out of the panel as its file (Finder, Mail, a chat). Only a press that starts on a result
    /// row arms it, so selecting text in the field never turns into a file drag.
    private func handleDrag(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        switch event.type {
        case .leftMouseDown:
            dragStart = model.hoveredID.flatMap { id in model.visibleRows.first { $0.id == id }?.result }
                .map { ($0, event.locationInWindow) }
            return false
        case .leftMouseDragged:
            guard let start = dragStart, let view = panel.contentView else { return false }
            let p = event.locationInWindow
            guard hypot(p.x - start.point.x, p.y - start.point.y) >= 4 else { return false }
            dragStart = nil
            let url = URL(fileURLWithPath: start.result.item.path)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let local = view.convert(start.point, from: nil)
            item.setDraggingFrame(NSRect(x: local.x - 16, y: local.y - 16, width: 32, height: 32), contents: icon)
            view.beginDraggingSession(with: [item], event: event, source: dragSource)
            return true
        default:
            dragStart = nil
            return false
        }
    }

    private var changesTask: Task<Void, Never>?
    private var staleResults = false
    private var lastInput = ContinuousClock.now
    private var staleTimer: Task<Void, Never>?

    private func refreshIfIdle() {
        guard staleResults, panel.isVisible, !isHiding, model.chips == nil, !model.isEmptyQuery else { return }
        let wait = lastInput + .seconds(1) - ContinuousClock.now
        if wait > .zero {
            guard staleTimer == nil else { return }
            staleTimer = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.staleTimer = nil
                self.refreshIfIdle()
            }
            return
        }
        staleResults = false
        model.refresh()
    }

    private func exclude(_ result: SearchResult) {
        guard let admin else { return }
        let item = result.item
        model.status.flash("Excluded \(DisplayText.name(item))")
        Task {
            await admin.exclude(item)
            model.refresh()
        }
    }

    private func toggleQuickLook() {
        guard let result = model.selectedResult, result.item.kind != .app else { return }
        admin?.indexNow(result.item)
        quickLook.url = URL(fileURLWithPath: result.item.path)
        quickLook.toggle()
    }

    private func syncQuickLook() {
        guard quickLook.isVisible, let result = model.selectedResult, result.item.kind != .app else { return }
        quickLook.url = URL(fileURLWithPath: result.item.path)
    }

    private func openWithChooser(_ result: SearchResult) {
        guard result.item.kind != .app else { return }
        let apps = DefaultApp.candidates(for: URL(fileURLWithPath: result.item.path))
        guard !apps.isEmpty else { return }
        model.openChips(apps.map { .openIn($0) }, chooser: true)
    }

    /// ⌘K: split the action chips off the slip (no-op without a slip).
    func toggleChips() {
        if model.chips != nil { model.closeChips(); return }
        guard let result = model.selectedResult else { return }
        let chips = PanelAction.chips(
            for: result, isPinned: admin?.isPinned(result.item) ?? false,
            isRunning: RunningApps.shared.isRunning(result.item.path), quitStalled: quitStalled(result))
        model.openChips(PanelAction.swapped(chips, option: NSEvent.modifierFlags.contains(.option)))
    }

    func runChip(_ action: PanelAction) {
        guard let result = model.selectedResult else { return }
        model.closeChips()
        perform(action, on: result)
    }

    private func perform(_ action: PanelAction, on result: SearchResult) {
        switch action {
        case .openWith: openWithChooser(result)
        case .reveal: reveal(result)
        case .quickLook: toggleQuickLook()
        case .copyPath: copyPath(result)
        case .pin, .unpin: togglePin(result)
        case .quit: quitApp(result)
        case .forceQuit: forceQuitApp(result)
        case .copyText: copyText(result)
        case .copyFile: copyFile(result)
        case .exclude: exclude(result)
        case .openIn(let app): open(result, with: app)
        }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let editor = panel.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return false }  // let the input method finish composing
        lastInput = ContinuousClock.now
        #if DEBUG
        Measure.shared.keyDown()
        #endif
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // P2: shortcuts by key position on non-Latin layouts (Russian ⌘K = "л" otherwise).
        let key = ShortcutResolver.key(keyCode: event.keyCode, typed: event.charactersIgnoringModifiers)

        if model.chips != nil, handleChipKey(event, mods: mods, key: key) { return true }

        switch (event.keyCode, mods) {
        case (126, []): model.move(-1); syncQuickLook(); return true  // ↑
        case (125, []): model.move(1); syncQuickLook(); return true  // ↓
        case (126, .option): model.jumpGroup(-1); syncQuickLook(); return true
        case (125, .option): model.jumpGroup(1); syncQuickLook(); return true
        case (126, .command): model.jumpEnd(false); syncQuickLook(); return true
        case (125, .command): model.jumpEnd(true); syncQuickLook(); return true
        case (123, []), (124, []):  // ← →: the favorites shelf when the caret is at the end of the query
            let caretAtEnd = (editor?.selectedRange().location ?? 0) >= (editor?.string.utf16.count ?? 0)
            guard caretAtEnd || model.isEmptyQuery else { return false }
            return model.moveOnRail(event.keyCode == 123 ? -1 : 1)
        case (48, []): return model.narrowToSelection()  // Tab
        case (48, .shift): return model.widen() || true
        case (36, []), (76, []): activate(); return true
        case (36, .command), (76, .command):
            if model.selectedRow?.id == .finder || model.isNoResults {
                searchInFinder(model.query)
            } else if let r = model.selectedResult {
                reveal(r)
            }
            return true
        case (53, _): escape(); return true
        default: break
        }

        if mods == .control, key == "n" { model.move(1); syncQuickLook(); return true }
        if mods == .control, key == "p" { model.move(-1); syncQuickLook(); return true }
        if mods == .command {
            switch key {
            case "k": toggleChips(); return true
            case "y": toggleQuickLook(); return true
            case "o": if let r = model.selectedResult { openWithChooser(r) }; return true
            case ",": hide(); onSettings?(nil); return true
            case "q": NSApp.terminate(nil); return true
            case "c":
                guard (editor?.selectedRange().length ?? 0) == 0, let r = model.selectedResult else { return false }
                copyPath(r)
                return true
            default:
                if let n = ShortcutResolver.digit(keyCode: event.keyCode) ?? Int(key), (1...8).contains(n) {
                    if let target = model.slotTarget(n) { open(target) }
                    return true
                }
            }
        }
        if mods == [.command, .shift] {
            switch key {
            case "c": if let r = model.selectedResult { copyPath(r) }; return true
            case "p", "f": if let r = model.selectedResult { togglePin(r) }; return true
            default: break
            }
        }
        if mods == [.command, .option], key == "c", let r = model.selectedResult { copyText(r); return true }
        if mods == [.command, .option, .shift], key == "c", let r = model.selectedResult { copyFile(r); return true }
        if mods == [.control, .option, .shift], key == "q", let r = model.selectedResult, r.item.kind == .app {
            forceQuitApp(r)
            return true
        }
        if mods == [.control, .shift], key == "q", let r = model.selectedResult, r.item.kind == .app {
            quitApp(r)
            return true
        }
        return false
    }

    /// While the chips are open: ←/→ focus, ↵ runs, the mnemonic letter picks, Esc closes the chips only.
    private func handleChipKey(_ event: NSEvent, mods: NSEvent.ModifierFlags, key: String) -> Bool {
        guard let state = model.chips else { return false }
        switch event.keyCode {
        case 123: model.focusChip(-1); return true
        case 124: model.focusChip(1); return true
        case 36, 76: runChip(state.actions[state.focus]); return true
        case 53:
            if state.isChooser, let r = model.selectedResult {
                model.openChips(
                    PanelAction.chips(
                        for: r, isPinned: admin?.isPinned(r.item) ?? false,
                        isRunning: RunningApps.shared.isRunning(r.item.path), quitStalled: quitStalled(r)))
            } else {
                model.closeChips()
                focusField()  // P12
            }
            return true
        default: break
        }
        if mods.isEmpty, let letter = key.first,
            let action = state.actions.first(where: { $0.mnemonic == letter })
        {
            runChip(action)
            return true
        }
        if mods == .command, key == "k" { model.closeChips(); focusField(); return true }
        // Anything else (typing) closes the chips and goes on to the field.
        model.closeChips()
        focusField()
        return false
    }

    /// Esc ladder: chips → Quick Look → narrowing → query → hide (one step per press).
    private func escape() {
        if model.chips != nil { model.closeChips(); return }
        if quickLook.isVisible { quickLook.close(); return }
        if model.widen() { return }
        if !model.query.isEmpty { model.setQuery(""); return }
        hide(deferOrderOut: true)
    }

    /// Keys typed while Quick Look is key (P20: also when a third-party QL extension holds first responder):
    /// ↑/↓ move the slip and QL follows; ↩ opens; ⌘K closes QL and opens the actions; Esc and ⌘Y close it.
    private func handleQuickLookKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = ShortcutResolver.key(keyCode: event.keyCode, typed: event.charactersIgnoringModifiers)
        switch QuickLookKeyRouter.route(keyCode: event.keyCode, modifiers: mods, key: key) {
        case .up: model.move(-1); syncQuickLook()
        case .down: model.move(1); syncQuickLook()
        case .open: quickLook.close(); panel.makeKey(); focusField(); activate()
        case .actions: quickLook.close(); panel.makeKey(); focusField(); toggleChips()
        case .close: quickLook.close(); panel.makeKey(); focusField()
        case .pass: return false
        }
        return true
    }
}

/// Copy for every destination: Finder copies the file, Mail and chats attach it.
final class ResultDragSource: NSObject, NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

/// P11 (TC#942/TC#853/TC#1096): the hotkey toggles. Visible → hide (even when another window holds key focus, e.g.
/// after a click elsewhere left the panel up); hidden → show.
enum HotkeyToggle {
    enum Action: Equatable { case show, hide }
    static func action(isVisible: Bool, isKey: Bool) -> Action {
        isVisible ? .hide : .show
    }
}

/// P20: key routing while Quick Look is up. Pure, so the table is unit-testable.
enum QuickLookKeyRouter {
    enum Route: Equatable { case up, down, open, actions, close, pass }
    static func route(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) -> Route {
        switch (keyCode, modifiers) {
        case (126, []): return .up
        case (125, []): return .down
        case (36, []), (76, []): return .open
        case (53, _): return .close
        default: break
        }
        if modifiers == .command, key == "y" { return .close }
        if modifiers == .command, key == "k" { return .actions }
        return .pass
    }
}
// P2: ShortcutResolver lives in HunchCore (Search/ShortcutResolver.swift) so its layout table is unit-tested.
