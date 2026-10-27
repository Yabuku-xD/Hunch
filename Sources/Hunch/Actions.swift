import AppKit
import HunchCore

/// One ⌘K chip. The set depends on the row kind and never exceeds 6, so there is no overflow.
enum PanelAction: Hashable, Identifiable {
    case openWith
    case reveal
    case quickLook
    case copyPath
    case pin
    case unpin
    case quit
    /// ⌥ alternate of Quit: `forceTerminate()`, for an app that hangs or ignores Quit.
    case forceQuit
    case copyText
    /// ⌥ alternate of Copy Path: the file itself on the pasteboard (paste into Finder, Mail, a chat).
    case copyFile
    /// P17: drop from the index and keep it out.
    case exclude
    /// Open With chooser page: one chip per candidate app.
    case openIn(URL)

    var id: String {
        switch self {
        case .openIn(let url): "openIn:" + url.path
        default: String(describing: self)
        }
    }

    var title: String {
        switch self {
        case .openWith: "Open With"
        case .reveal: "Show in Finder"
        case .quickLook: "Quick Look"
        case .copyPath: "Copy Path"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .quit: "Quit"
        case .forceQuit: "Force Quit"
        case .copyText: "Copy Text"
        case .copyFile: "Copy File"
        case .exclude: "Exclude from Search"
        case .openIn(let url):
            FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    var symbol: String {
        switch self {
        case .openWith: "arrow.up.forward.app"
        case .reveal: "folder"
        case .quickLook: "eye"
        case .copyPath: "doc.on.doc"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .quit: "xmark.circle"
        case .forceQuit: "xmark.octagon.fill"
        case .copyText: "text.quote"
        case .copyFile: "doc.on.clipboard"
        case .exclude: "eye.slash"
        case .openIn: "app"
        }
    }

    /// The letter that picks this chip while chips are open (underlined in the focused label).
    var mnemonic: Character? {
        switch self {
        case .openWith: "w"
        case .reveal: "f"
        case .quickLook: "l"
        case .copyPath, .copyFile: "c"
        case .pin: "p"
        case .unpin: "u"
        case .quit, .forceQuit: "q"
        case .copyText: "t"
        case .exclude: "x"
        case .openIn: nil
        }
    }

    /// Direct chord, as keycaps.
    var keycaps: [String] {
        switch self {
        case .openWith: ["⌘", "O"]
        case .reveal: ["⌘", "↵"]
        case .quickLook: ["⌘", "Y"]
        case .copyPath: ["⌘", "⇧", "C"]
        case .pin, .unpin: ["⌘", "⇧", "P"]
        case .quit: ["⌃", "⇧", "Q"]
        case .forceQuit: ["⌃", "⌥", "⇧", "Q"]
        case .copyText: ["⌥", "⌘", "C"]
        case .copyFile: ["⌥", "⇧", "⌘", "C"]
        case .exclude, .openIn: []
        }
    }

    /// The chip shown in this one's place while ⌥ is held (macOS menu convention), and back.
    var alternate: PanelAction? {
        switch self {
        case .quit: .forceQuit
        case .copyPath: .copyFile
        default: nil
        }
    }

    var primary: PanelAction? {
        switch self {
        case .forceQuit: .quit
        case .copyFile: .copyPath
        default: nil
        }
    }

    /// The set with every chip in its ⌥ (or plain) form; chips without an alternate stay.
    static func swapped(_ actions: [PanelAction], option: Bool) -> [PanelAction] {
        actions.map { (option ? $0.alternate : $0.primary) ?? $0 }
    }

    /// Chips for a result. Apps: no Open With / Quick Look; Quit only while running, Force Quit in its place once a
    /// Quit was asked for and the app is still running (`quitStalled`).
    @MainActor
    static func chips(
        for result: SearchResult, isPinned: Bool, isRunning: Bool, quitStalled: Bool = false
    ) -> [PanelAction] {
        if result.item.kind == .setting { return [isPinned ? .unpin : .pin] }
        var out: [PanelAction] = []
        if result.item.kind != .app { out.append(.openWith) }
        out.append(.reveal)
        if result.item.kind != .app { out.append(.quickLook) }
        out.append(.copyPath)
        out.append(isPinned ? .unpin : .pin)
        if result.item.kind == .app, isRunning { out.append(quitStalled ? .forceQuit : .quit) }
        if result.match != nil, out.count < 6 { out.append(.copyText) }
        if result.item.kind != .app, out.count < 6 { out.append(.exclude) }
        return Array(out.prefix(6))
    }
}

/// The ⌘K strip state: which chips, which one is focused.
struct ChipState: Equatable {
    var actions: [PanelAction]
    var focus: Int
    /// Showing the Open With app chips (← or Esc goes back to the actions).
    var isChooser: Bool
}
