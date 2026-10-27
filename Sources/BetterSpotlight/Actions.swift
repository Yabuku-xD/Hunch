import AppKit
import SpotCore

/// One ⌘K chip. The set depends on the row kind and never exceeds 6, so there is no overflow.
enum PanelAction: Hashable, Identifiable {
    case openWith
    case reveal
    case quickLook
    case copyPath
    case pin
    case unpin
    case quit
    case copyText
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
        case .copyText: "Copy Text"
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
        case .copyText: "text.quote"
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
        case .copyPath: "c"
        case .pin: "p"
        case .unpin: "u"
        case .quit: "q"
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
        case .copyText: ["⌥", "⌘", "C"]
        case .exclude, .openIn: []
        }
    }

    /// Chips for a result. Apps: no Open With / Quick Look; Quit only while running.
    @MainActor
    static func chips(for result: SearchResult, isPinned: Bool, isRunning: Bool) -> [PanelAction] {
        var out: [PanelAction] = []
        if result.item.kind != .app { out.append(.openWith) }
        out.append(.reveal)
        if result.item.kind != .app { out.append(.quickLook) }
        out.append(.copyPath)
        out.append(isPinned ? .unpin : .pin)
        if result.item.kind == .app, isRunning { out.append(.quit) }
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
