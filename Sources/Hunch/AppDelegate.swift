import AppKit
import HunchCore

/// Owns the hotkey, the menu-bar item, the panel and Settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let reopenNotification = Notification.Name("dev.hunch.reopen")

    struct Launch {
        var showPanel = false
        var query: String?
        var showActions = false
        var showSettings = false
        var measure = false
    }

    private let engine: any SearchEngine
    /// Real index + model; nil when a DEBUG fixture engine is in use.
    private let backend: SearchBackend?
    private let launch: Launch
    private var admin: IndexAdmin?
    private var panelController: PanelController?
    private var settings: SettingsWindowController?
    private var guide: OnboardingWindowController?
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var statusLineTask: Task<Void, Never>?
    private var models: (any ModelProviding)?
    private var recorder: ShortcutRecorderModel?
    private var hotKeyFailed = false

    init(engine: any SearchEngine, backend: SearchBackend?, launch: Launch) {
        self.engine = engine
        self.backend = backend
        self.launch = launch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Thin overlay scrollers everywhere in the app (no legacy scrollers in Settings either).
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])
        if let appearance = DebugOverrides.appearance { NSApp.appearance = appearance }
        let models = ModelProviders.make()
        self.models = models
        if let backend {
            admin = BackendIndexAdmin(backend: backend, models: models)
        }
        #if DEBUG
        if let fixture = engine as? PreviewEngine { admin = FixtureIndexAdmin(engine: fixture, models: models) }
        #endif
        let controller = PanelController(engine: engine, admin: admin)
        panelController = controller
        let recorder = ShortcutRecorderModel()
        self.recorder = recorder
        let settingsModel = SettingsModel(
            admin: admin, status: controller.model.status, models: models, recorder: recorder)
        let settings = SettingsWindowController(model: settingsModel)
        self.settings = settings
        let admin = self.admin
        let guide = OnboardingWindowController { reopened, step in
            OnboardingModel(recorder: recorder, models: models, admin: admin, reopened: reopened, forcedStep: step)
        }
        self.guide = guide
        settingsModel.onWelcome = { guide.show(reopened: true) }
        controller.onSettings = { settings.show(pane: $0) }
        controller.onModelSetup = { [weak self] in self?.openModelSetup() }
        backend?.start()  // loads the index from disk, then catches up in the background
        controller.prewarm()

        HotKey.shared.action = { controller.toggle() }
        let wanted = Shortcut.saved ?? .optionSpace
        // U4: no fallback chord (⌃Space and ⌥⌘Space belong to macOS). A taken chord registers nothing.
        if !HotKey.shared.register(wanted) {
            NSLog("%@: %@ is already in use", AppInfo.name, wanted.displayString)
            hotKeyFailed = true
            recorder.reportConflict(wanted)
        }

        MainMenu.install(
            .init(
                about: { MainMenu.showAbout() },
                settings: { settings.show() },
                welcome: { guide.show(reopened: true) },
                selectPane: { settings.select($0) },
                settingsIsKey: { settings.isKey }))
        #if DEBUG
        // Scripted runs (screenshots, probes) start and quit within seconds. A status item that appears and vanishes
        // hundreds of times under the shipping bundle id confuses menu bar managers (Dimble, Ice, Bartender), which
        // remember items by bundle id, so these runs add none.
        let env = ProcessInfo.processInfo.environment
        let scriptedRun =
            launch.showPanel || launch.showSettings || launch.measure || env["HUNCH_HIDDEN"] == "1"
            || env["HUNCH_FIXTURE"] != nil || env["HUNCH_PROBE"] == "1"
        if !scriptedRun { installStatusItem(controller: controller, settings: settings, guide: guide) }
        #else
        installStatusItem(controller: controller, settings: settings, guide: guide)
        #endif

        DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { settings.show() }
        }
        NotificationCenter.default.addObserver(forName: .onboardingWantsPanel, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { controller.show() }
        }
        // The roots count for the no-results footnote, refreshed when the roots change (never per keystroke).
        controller.model.rootsCount = self.admin?.userRootsCount ?? 0

        #if DEBUG
        if launch.measure {
            runMeasurement(controller)
            return
        }
        #endif
        if launch.showPanel {
            controller.show()
            if let query = launch.query {
                controller.model.setQuery(query)
                // The index loads in the background; re-run the launch query once it has caught up.
                if let backend {
                    Task { @MainActor in
                        await backend.wait(for: .caughtUp)
                        guard controller.model.query == query else { return }
                        controller.model.refresh()
                    }
                }
            }
            if launch.showActions {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))  // after the content batch lands
                    controller.toggleChips()
                }
            }
        }
        #if DEBUG
        if launch.showSettings {
            settings.show(pane: DebugOverrides.settingsPane.flatMap(SettingsPane.init(rawValue:)))
        }
        if DebugOverrides.welcome { guide.show(reopened: true) }
        if let step = DebugOverrides.onboardingStep { guide.show(reopened: false, step: step) }
        if let n = DebugOverrides.hoverRow {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                controller.model.hoverForDebug(row: n)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["HUNCH_DUMPLAYERS"] == "1", let root = controller.hostingForDebug?.layer
        {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                func dump(_ l: CALayer, _ d: Int) {
                    guard d < 40 else { return }
                    let pad = String(repeating: " ", count: d)
                    var s = "\(pad)\(type(of: l)) \(l.frame.integral)"
                    if let c = l.compositingFilter { s += " comp=\(c)" }
                    if let f = l.filters, !f.isEmpty { s += " filters=\(f)" }
                    if l.contents != nil { s += " contents" }
                    if let bg = l.backgroundColor { s += " bg=\(bg)" }
                    if l.delegate != nil { s += " del=\(type(of: l.delegate!))" }
                    print(s)
                    for c in l.sublayers ?? [] { dump(c, d + 1) }
                }
                dump(root, 0)
                fflush(stdout)
            }
        }
        #endif
        #if DEBUG
        let scripted =
            launch.showPanel || launch.showSettings || ProcessInfo.processInfo.environment["HUNCH_HIDDEN"] == "1"
        #else
        let scripted = false
        #endif
        #if DEBUG
        let guideForced = DebugOverrides.onboardingStep != nil || DebugOverrides.welcome
        #else
        let guideForced = false
        #endif
        let loginItem = launchedAsLoginItem
        let firstRun = OnboardingFlow.showsAtLaunch(
            defaults: AppDefaults.store, isLoginItem: loginItem, scripted: scripted)
        if firstRun, !guideForced {
            // U5: first launch shows the guide instead of the panel (at step 2 when the chord is taken).
            guide.show(reopened: false, step: hotKeyFailed ? 2 : nil)
        } else if hotKeyFailed, !guideForced, !launch.showSettings {
            // The only reason Settings opens by itself: the chord could not be registered.
            settings.show(pane: .general)
        } else if LaunchKind.opensSettings(isLoginItem: loginItem, scripted: scripted) {
            // A launch by the user (Spotlight, Finder, `open`) opens Settings; a login-item launch stays in the menu bar.
            settings.show()
        }
    }

    /// Opening the app again while it runs (Spotlight, Finder, Dock) opens Settings; the panel has its shortcut.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return false
    }

    /// The model-missing status: the guide at step 4, or Settings › Index once the guide is complete.
    private func openModelSetup() {
        if AppDefaults.store.bool(forKey: OnboardingFlow.completedKey) {
            settings?.show(pane: .index)
        } else {
            guide?.show(reopened: false, step: 4)
        }
    }

    // MARK: Status item (U7)

    /// The app icon's mark as an 18 pt template: the orb's outline with the glint inside. Needing attention adds a dot.
    static func statusMark(attention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let orb = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            orb.lineWidth = 1.5
            orb.stroke()
            let c = NSPoint(x: 10.5, y: 10.5), l: CGFloat = 4.2, s: CGFloat = 3.6
            let tips = [
                NSPoint(x: c.x, y: c.y + l), NSPoint(x: c.x + s, y: c.y),
                NSPoint(x: c.x, y: c.y - l), NSPoint(x: c.x - s, y: c.y),
            ]
            let star = NSBezierPath()
            star.move(to: tips[0])
            for i in 0..<4 {
                let a = tips[i], b = tips[(i + 1) % 4]
                let ctrl = NSPoint(x: c.x + ((a.x + b.x) / 2 - c.x) * 0.15, y: c.y + ((a.y + b.y) / 2 - c.y) * 0.15)
                star.curve(to: b, controlPoint1: ctrl, controlPoint2: ctrl)
            }
            star.close()
            star.fill()
            if attention { NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 6, height: 6)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = attention ? "\(AppInfo.name), needs attention" : AppInfo.name
        return image
    }

    private func installStatusItem(
        controller: PanelController, settings: SettingsWindowController,
        guide: OnboardingWindowController
    ) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A stable name, so macOS and menu bar managers remember where the user put the item across launches.
        item.autosaveName = AppInfo.name
        let attention = hotKeyFailed || modelFailed
        item.button?.image = Self.statusMark(attention: attention)
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(ClosureMenuItem(title: "Open \(AppInfo.name)") { controller.show() })
        menu.addItem(.separator())
        let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        statusLine = line
        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { settings.show() })
        menu.addItem(ClosureMenuItem(title: "Welcome Guide…") { guide.show(reopened: true) })
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private var modelFailed: Bool {
        if case .failed = models?.state { return true }
        return false
    }

    /// The first line: the problem when there is one, else the band's status text, else "Up to date".
    private func statusLineText() -> String {
        var text: String
        if hotKeyFailed, let s = recorder?.shortcut {
            text = HotKeyPolicy.conflictMessage(s)
        } else if modelFailed, case .failed(let e, _) = models?.state {
            text = ModelCopy.failure(e)
        } else {
            text = panelController?.model.status.text ?? "Up to date"
        }
        return text
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLine?.title = statusLineText()
        // Live only while open: one observation re-arm per change, dropped in menuDidClose.
        statusLineTask?.cancel()
        statusLineTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.panelController?.model.status.text
                    } onChange: {
                        c.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.statusLine?.title = self.statusLineText()
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusLineTask?.cancel()
        statusLineTask = nil
    }

    /// `keyAELaunchedAsLogInItem` in the launch Apple event (set by launchd/SMAppService for login items).
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Leave without C++ static destructors: Homebrew ggml's Metal device destructor asserts
    /// (`ggml-metal-device.m:1041 GGML_ASSERT([rsets->data count] == 0)`) while a loaded model still holds residency
    /// sets, which turned every Quit into an abort + crash report. main.swift disables residency sets; this also
    /// covers a user who re-enables them. Nothing of ours needs atexit work: SQLite commits and defaults writes are
    /// already durable.
    func applicationWillTerminate(_ notification: Notification) {
        fflush(stdout)
        fflush(stderr)
        _exit(0)
    }

    #if DEBUG
    /// `--measure`: 20 hide → hotkey → show cycles and 20 keystroke → results cycles, through the same code paths
    /// as real input (the Carbon handler entry point, real keyDown events into the field editor). Prints each sample,
    /// then p50/p95. The very first keystroke after launch (cold: SwiftUI instantiates the row types) is printed
    /// separately as `cold_first_results_ms` and kept out of the percentiles, like the first show.
    private func runMeasurement(_ controller: PanelController) {
        Measure.shared.enabled = true
        Task { @MainActor in
            // Warm-up: first show builds the view graph once.
            controller.show()
            try? await Task.sleep(for: .milliseconds(400))
            for _ in 0..<20 {
                controller.hide()
                try? await Task.sleep(for: .milliseconds(80))
                Measure.shared.hotKeyPressed()
                controller.toggle()
                try? await Task.sleep(for: .milliseconds(80))
            }
            // Warm-up keystroke (cold sample reported on its own).
            Measure.shared.resultLabel = "cold_first_results_ms"
            controller.model.setQuery("")
            try? await Task.sleep(for: .milliseconds(120))
            controller.typeForMeasurement("e")
            try? await Task.sleep(for: .milliseconds(200))
            Measure.shared.resetResultSamples()
            Measure.shared.resultLabel = "first_results_ms"
            // 20 typed characters, word by word from an empty field: real keyDown events through the monitors and the
            // field editor, so the clock starts where a user's keystroke does.
            // HUNCH_ROWBENCH=N (scratch A/B only): N passes, then commit percentiles and exit (no idle window).
            let reps = ProcessInfo.processInfo.environment["HUNCH_ROWBENCH"].flatMap(Int.init) ?? 1
            for _ in 0..<reps {
                for word in ["saf", "cal", "no", "pre", "doc", "inv", "acm"] {
                    controller.model.setQuery("")
                    try? await Task.sleep(for: .milliseconds(120))
                    for character in word {
                        controller.typeForMeasurement(String(character))
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                }
            }
            let m = Measure.shared
            if reps > 1 {
                Measure.emit(
                    String(
                        format: "rowbench commit p50=%.2f p75=%.2f p95=%.2f first p50=%.2f p95=%.2f n=%d",
                        Measure.percentile(m.commitSamples, 0.5), Measure.percentile(m.commitSamples, 0.75),
                        Measure.percentile(m.commitSamples, 0.95), Measure.percentile(m.resultSamples, 0.5),
                        Measure.percentile(m.resultSamples, 0.95), m.commitSamples.count))
                NSApp.terminate(nil)
            }
            Measure.emit(
                String(
                    format: "summary panel_show_ms p50=%.2f p95=%.2f n=%d target<=14",
                    Measure.percentile(m.showSamples, 0.5), Measure.percentile(m.showSamples, 0.95),
                    m.showSamples.count))
            Measure.emit(
                String(
                    format: "summary first_results_ms p50=%.2f p95=%.2f n=%d target<=33",
                    Measure.percentile(m.resultSamples, 0.5), Measure.percentile(m.resultSamples, 0.95),
                    m.resultSamples.count))
            Measure.emit(
                String(
                    format: "summary commit_ms p50=%.2f p95=%.2f n=%d target<=12",
                    Measure.percentile(m.commitSamples, 0.5), Measure.percentile(m.commitSamples, 0.95),
                    m.commitSamples.count))
            // Idle: panel hidden, no input; whole-process CPU over 10 s (index lanes, display links, timers).
            // "Idle" = no pending index work: first let any catch-up (FSEvents replay of changes made since the last
            // run, e.g. a build in ~/Downloads) drain, up to 60 s, and report how long that took.
            controller.hide()
            let settleStart = ContinuousClock.now
            while ContinuousClock.now - settleStart < .seconds(60) {
                let c = Measure.cpuSeconds()
                try? await Task.sleep(for: .seconds(2))
                if (Measure.cpuSeconds() - c) / 2 * 100 < 0.5 { break }
            }
            Measure.emit(String(format: "idle_settle_s=%.1f", (ContinuousClock.now - settleStart) / .seconds(1)))
            let cpu0 = Measure.cpuSeconds(), t0 = ContinuousClock.now
            try? await Task.sleep(for: .seconds(10))
            let idlePct = (Measure.cpuSeconds() - cpu0) / ((ContinuousClock.now - t0) / .seconds(1)) * 100
            Measure.emit(String(format: "summary idle_cpu_pct=%.3f window_s=10 target<=0.1", idlePct))
            // U15 hover phase: panel shown with results, row 2 hovered with the pointer still (the HUNCH_HOVER_ROW path),
            // 2 s to settle, then whole-process CPU over 10 s and the footprint change against the idle phase.
            let idleFootprint = Measure.footprintMB()
            controller.show()
            controller.model.setQuery("e")
            try? await Task.sleep(for: .seconds(2))
            let scpu0 = Measure.cpuSeconds(), st0 = ContinuousClock.now
            try? await Task.sleep(for: .seconds(10))
            let shownPct = (Measure.cpuSeconds() - scpu0) / ((ContinuousClock.now - st0) / .seconds(1)) * 100
            let shownFootprint = Measure.footprintMB()
            // Shown-panel costs (the caret blink, the results' icons and layers), reported for reference: they are what
            // showing the panel costs, not what hovering costs.
            Measure.emit(String(format: "shown_idle_cpu_pct=%.3f window_s=10", shownPct))
            Measure.emit(String(format: "shown_footprint_delta_mb=%.2f", shownFootprint - idleFootprint))
            // The hover gates measure hover's own cost: the same shown panel with a row hovered, against it unhovered.
            controller.model.hoverForDebug(row: 2)
            try? await Task.sleep(for: .seconds(2))
            let hcpu0 = Measure.cpuSeconds(), ht0 = ContinuousClock.now
            try? await Task.sleep(for: .seconds(10))
            let hoverPct = (Measure.cpuSeconds() - hcpu0) / ((ContinuousClock.now - ht0) / .seconds(1)) * 100
            Measure.emit(String(format: "hover_idle_cpu_pct=%.3f window_s=10", hoverPct))
            Measure.emit(
                String(
                    format: "summary hover_idle_cpu_delta_pct=%.3f window_s=10 target<=0.05",
                    hoverPct - shownPct))
            // Footprint after hovering across several rows: a per-row render surface (a fill inside the glass content
            // kept ~16 MB per hovered row until hide) shows up only once more than one row has been hovered.
            for n in [3, 1, 4, 0, 2] {
                controller.model.hoverForDebug(row: n)
                try? await Task.sleep(for: .milliseconds(500))
            }
            Measure.emit(
                String(
                    format: "summary hover_footprint_delta_mb=%.2f target<=1",
                    Measure.footprintMB() - shownFootprint))
            controller.hide()
            if !launch.showPanel { NSApp.terminate(nil) }
        }
    }
    #endif
}

/// Whether a launch should open Settings. Pure, so it is unit-testable.
enum LaunchKind {
    static func opensSettings(isLoginItem: Bool, scripted: Bool) -> Bool {
        !isLoginItem && !scripted
    }
}
