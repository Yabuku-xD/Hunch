import AppKit

/// U3/F6: the main menu, so ⌘W, ⌘Q, ⌘V, ⌘, and ⌘1–⌘4 work in Settings, the guide and open/save sheets.
@MainActor
enum MainMenu {
    struct Handlers {
        var about: () -> Void
        var settings: () -> Void
        var welcome: () -> Void
        var selectPane: (SettingsPane) -> Void
        var settingsIsKey: @MainActor () -> Bool
    }

    static func install(_ h: Handlers) {
        let main = NSMenu()

        let appMenu = NSMenu(title: AppInfo.name)
        appMenu.addItem(ClosureMenuItem(title: "About \(AppInfo.name)") { h.about() })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { h.settings() })
        appMenu.addItem(ClosureMenuItem(title: "Welcome Guide…") { h.welcome() })
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: AppInfo.name)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        for (i, pane) in SettingsPane.allCases.enumerated() {
            let item = ClosureMenuItem(title: pane.title, key: "\(i + 1)") { h.selectPane(pane) }
            item.isEnabledCheck = h.settingsIsKey
            window.addItem(item)
        }
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    /// The standard About panel with our credits.
    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Runs entirely on this Mac.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let link = NSAttributedString(
            string: "Licenses",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: AppInfo.repoURL.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"),
            ])
        credits.append(link)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppInfo.name, .credits: credits])
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// Menu item that runs a closure; optionally enabled only while `isEnabledCheck` is true.
final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: @MainActor () -> Void
    var isEnabledCheck: (@MainActor () -> Bool)?

    init(title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func run() {
        handler()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated { isEnabledCheck?() ?? true }
    }
}
