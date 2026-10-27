import AppKit
import Observation
import SpotCore
import SwiftUI

/// Query → engine stream → fixed-pitch rows + the slip (selection). All geometry lives here so the glass path, the
/// rows and the scroll offset are computed from one source, synchronously, without measuring SwiftUI.
@MainActor
@Observable
final class SearchModel {
    static let groupCap = 6
    static let queryLimit = 1_000

    var theme: Theme = .large
    /// The target screen's backing scale, set once per show (F11: proofs never read `NSScreen.main`).
    var displayScale: CGFloat = 2
    /// Roots count for the no-results footnote (U10); set when the roots change, never per keystroke.
    @ObservationIgnored var rootsCount = 0
    /// Favorites whose file is gone, computed once per suggestions batch (never `fileExists` in a body, M4).
    private(set) var railMissing: Set<UInt32> = []

    private(set) var query = ""
    private(set) var rows: [Row] = []
    /// Height of all rows including each row's lane.
    private(set) var contentHeight: CGFloat = 0
    /// "No matches…" (drawn above the Finder row) or "1 match" (drawn below the only row).
    private(set) var message: ListMessage?
    private(set) var selectedID: RowID?
    private(set) var railIndex = 0
    private(set) var scrollOffset: CGFloat = 0
    private(set) var hoveredID: RowID?
    private(set) var railHover: Int?
    /// Tab narrowing: only this group is shown.
    private(set) var narrowed: DisplayGroup?
    private(set) var chips: ChipState?
    /// Replaces the slip's "↵ verb" hint ("No longer exists", an open error).
    private(set) var slipHint: String?
    private(set) var commandHeld = false
    /// Indeterminate ring: shown only when this query's stream runs longer than 150 ms.
    private(set) var isSearching = false
    /// Thin overlay scroller is shown while scrolling, then fades.
    private(set) var scrollerVisible = false
    private(set) var focusToken = 0
    private(set) var selectAllToken = 0
    /// An input method has marked (uncommitted) text in the field: names only, prompt hidden (P1, P21, U12).
    private(set) var isComposing = false

    let status = StatusModel()
    /// The window only changes between band-only and full height; the controller resizes it in the same pass.
    @ObservationIgnored var onHeightChange: (() -> Void)?

    @ObservationIgnored private let engine: any SearchEngine
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var ringTask: Task<Void, Never>?
    @ObservationIgnored private var ringHideTask: Task<Void, Never>?
    /// U12/F24: once shown, the spinner stays until this instant (checked when hiding; no timer).
    @ObservationIgnored private var ringShownAt: CFTimeInterval = 0
    @ObservationIgnored private var scrollerTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var frozen = Frozen()
    @ObservationIgnored private var expanded: Set<DisplayGroup> = []
    @ObservationIgnored private var favorites: [SearchResult] = []
    @ObservationIgnored private var streamFinished = true
    /// The current query ran names-only (composition); the commit must run the content legs even if the text is equal.
    @ObservationIgnored private var ranNamesOnly = false
    @ObservationIgnored private var lastApplyAt: CFTimeInterval = 0
    private static let framePacing: CFTimeInterval = 0.012
    /// Pointer location when hover was last disarmed (keyboard move, list change). Hover re-arms after 3 pt.
    @ObservationIgnored private var hoverAnchor: NSPoint?
    /// Groups of the current query string; rows above the slip never reorder while it lives.
    private struct Frozen {
        var topID: UInt32?
        var results: [UInt32: SearchResult] = [:]
        var order: [DisplayGroup: [UInt32]] = [:]
        var group: [UInt32: DisplayGroup] = [:]
    }

    init(engine: any SearchEngine) {
        self.engine = engine
    }

    // MARK: Derived

    var hasResults: Bool { !rows.isEmpty || message != nil }
    var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var panelHeight: CGFloat { hasResults ? theme.slabHeight : theme.bandHeight }
    /// The footer is the slab's last section; hidden on an empty query with no status. The slab keeps its height and
    /// the list gives the footer its room, so the window never resizes for it.
    var showsFooter: Bool { hasResults && (!isEmptyQuery || status.text != nil) }
    var footerHeight: CGFloat { showsFooter ? theme.footerHeight : 0 }
    var viewportHeight: CGFloat { theme.resultsHeight - footerHeight }
    var maxOffset: CGFloat { max(0, totalHeight - viewportHeight) }
    var totalHeight: CGFloat { contentHeight + (message != nil && !rows.isEmpty && !isNoResults ? 28 : 0) }
    var isNoResults: Bool { rows.count == 1 && rows.first?.id == .finder }
    var selectedRow: Row? { selectedID.flatMap { id in rows.first { $0.id == id } } }

    /// The result the slip acts on (the focused favorite on the rail).
    var selectedResult: SearchResult? {
        guard let row = selectedRow else { return nil }
        if case .rail(let items) = row.content { return items.indices.contains(railIndex) ? items[railIndex] : nil }
        return row.result
    }

    /// Slip edges in list coordinates (before scrolling), or nil without a selection.
    var slipSpan: ClosedRange<CGFloat>? {
        guard let row = selectedRow else { return nil }
        return row.y...(row.y + row.height)
    }

    /// Rows intersecting the viewport, for lazy rendering. No slack: every scroll step recomputes this in the same
    /// transaction, and each off-screen row costs ≈ 1 ms of layout on the keystroke that replaces the list.
    var visibleRows: ArraySlice<Row> {
        let top = scrollOffset, bottom = scrollOffset + viewportHeight
        guard let first = rows.firstIndex(where: { $0.y + $0.height > top }) else { return [] }
        let last = rows.lastIndex(where: { $0.y < bottom }) ?? first
        return first <= last ? rows[first...last] : []
    }

    /// The primary verb named inside the slip.
    var primaryVerb: String {
        guard let row = selectedRow else { return "" }
        switch row.content {
        case .finder: return "Search in Finder"
        case .showAll: return "Show All"
        default: break
        }
        guard let result = selectedResult else { return "Open" }
        switch result.item.kind {
        case .app: return RunningApps.shared.isRunning(result.item.path) ? "Switch To" : "Open"
        case .folder: return "Open"
        case .file: return DefaultApp.name(for: result.item.path).map { "Open in \($0)" } ?? "Open"
        }
    }

    // MARK: Query

    func setQuery(_ raw: String) {
        var value = raw
        if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            // Pasted multi-line text: newlines/tabs become single spaces and runs collapse.
            value = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        }
        if value.count > Self.queryLimit {
            value = String(value.prefix(Self.queryLimit))
            status.flash("Trimmed to 1,000 characters")
        }
        guard value != query else {
            if ranNamesOnly, !isComposing { run() }
            return
        }
        query = value
        #if DEBUG
        Measure.shared.queryChanged(generation: generation + 1)
        #endif
        run()
    }

    /// Called after every key the field editor handled. Leaving composition runs the full query once.
    func setComposing(_ composing: Bool) {
        guard composing != isComposing else { return }
        isComposing = composing
        if !composing, ranNamesOnly { run() }
    }

    /// U11: one throwaway name query while the panel is ordered out (engine fold tables, buckets, row types), then
    /// back to the root state. Content legs are skipped.
    func prewarmQuery() {
        for probe in ["a", "e"] { _ = engine.start(probe) }
        run()
    }

    /// Re-runs the current query (index caught up, pins changed).
    func refresh() {
        let keep = selectedID
        run()
        if let keep, rows.contains(where: { $0.id == keep }) { selectedID = keep }
    }

    private func run() {
        streamTask?.cancel()
        ringTask?.cancel()
        hideRing()
        ranNamesOnly = false
        generation += 1
        chips = nil
        slipHint = nil
        expanded = []
        frozen = Frozen()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showSuggestions()
            return
        }
        let current = generation
        streamFinished = false
        // The name batch comes back synchronously and is applied inside this call, so it lands in the keystroke's
        // frame. Reading it from the stream instead would let SwiftUI draw the bare query change first and put the
        // results one frame later (measured +5–13 ms on first_results_ms).
        let (names, stream) = engine.start(trimmed)
        var first = true
        if let names {
            apply(names, first: true)
            first = false
        }
        // P1/U12: while an input method composes, the text is not final; no full-text / semantic legs per
        // composition change. The stream is dropped (its termination cancels the engine's content work).
        ranNamesOnly = isComposing
        if isComposing {
            streamFinished = true
            return
        }
        streamTask = Task { [weak self, first] in
            var first = first
            for await batch in stream {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                // Frame pacing: a content batch that lands right after the name batch would run its SwiftUI update
                // before the name results' frame is drawn and push that frame back (measured +4–8 ms). Let one frame
                // pass first; content rows arrive ≤ 12 ms later, below anything a reader can see.
                let since = CACurrentMediaTime() - self.lastApplyAt
                if since < Self.framePacing {
                    try? await Task.sleep(for: .seconds(Self.framePacing - since))
                    guard !Task.isCancelled, self.generation == current else { return }
                }
                self.apply(batch, first: first)
                first = false
            }
            guard let self, self.generation == current else { return }
            self.streamFinished = true
            self.ringTask?.cancel()
            self.hideRing()
        }
        ringTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SpinnerPolicy.showDelay))
            guard let self, !Task.isCancelled, self.generation == current, !self.streamFinished else { return }
            self.ringHideTask?.cancel()
            if !self.isSearching {
                self.isSearching = true
                self.ringShownAt = CACurrentMediaTime()
            }
        }
    }

    /// Hides the spinner now, or at `SpinnerPolicy.hideAt` if it has not been up for its minimum yet.
    private func hideRing() {
        guard isSearching else { return }
        let now = CACurrentMediaTime()
        let at = SpinnerPolicy.hideAt(shownAt: ringShownAt, finishedAt: now)
        guard at > now else { isSearching = false; return }
        ringHideTask?.cancel()
        ringHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(at - now))
            guard let self, !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    func reset() {
        narrowed = nil
        query = ""
        run()
    }

    func didShow() {
        focusToken &+= 1
    }

    /// Reopened within 60 s: the old query comes back fully selected so typing replaces it.
    func didRestore() {
        selectAllToken &+= 1
    }

    private func showSuggestions() {
        let sections = engine.suggestions()
        favorites = sections.first { $0.kind == .favorites }?.results ?? []
        let missing = Set(favorites.prefix(8).filter { !FileManager.default.fileExists(atPath: $0.item.path) }.map(\.id))
        if missing != railMissing { railMissing = missing }
        let recents = sections.first { $0.kind == .recents }?.results ?? []
        var builder = RowBuilder(theme: theme)
        if !favorites.isEmpty {
            builder.add(.rail, .rail(Array(favorites.prefix(8))), .favorites, theme.railContent, first: true, last: true)
        }
        for (i, r) in recents.prefix(8).enumerated() {
            builder.add(.item(r.id), .name(r), .recents, theme.nameContent, first: i == 0, last: i == min(recents.count, 8) - 1)
        }
        commit(builder, message: nil, keepSelection: false)
        // hotkey → ↵ reopens the last item: the slip starts on Recents row 1, else on the shelf.
        selectedID = recents.isEmpty ? (favorites.isEmpty ? nil : .rail) : .item(recents[0].id)
        railIndex = 0
    }

    private func apply(_ batch: [SearchResult], first: Bool) {
        lastApplyAt = CACurrentMediaTime()
        var seen = Set<UInt32>()
        let unique = batch.filter { seen.insert($0.id).inserted }
        if first { frozen = Frozen() }
        for result in unique {
            if frozen.results[result.id] == nil {
                if frozen.topID == nil, frozen.results.isEmpty {
                    frozen.topID = result.id
                } else {
                    let group = result.naturalGroup
                    frozen.group[result.id] = group
                    frozen.order[group, default: []].append(result.id)
                }
            }
            frozen.results[result.id] = result
        }
        rebuild(keepSelection: !first)
        #if DEBUG
        if first, ProcessInfo.processInfo.environment["BS_COMMIT_SPLIT"] == "1" {
            let kinds = visibleRows.map { row -> String in
                switch row.content {
                case .name: "n"
                case .evidence: "e"
                case .rail: "r"
                case .showAll: "s"
                case .finder: "f"
                }
            }
            Measure.emit("commit_rows q=\(query) \(kinds.joined())")
        }
        if first { Measure.shared.resultsApplied(generation: generation) }
        #endif
    }

    private func rebuild(keepSelection: Bool) {
        var builder = RowBuilder(theme: theme)
        let top = frozen.topID.flatMap { frozen.results[$0] }
        let topGroup = top?.naturalGroup
        if let top, narrowed == nil || narrowed == topGroup {
            builder.add(.item(top.id), top.match == nil ? .name(top) : .evidence(top), .topHit,
                        top.match == nil ? theme.nameContent : theme.evidenceContent, first: true, last: true)
        }
        for group in DisplayGroup.allCases where group > .topHit {
            if let narrowed, narrowed != group { continue }
            let ids = frozen.order[group] ?? []
            guard !ids.isEmpty else { continue }
            let open = narrowed != nil || expanded.contains(group)
            let shown = open ? ids[...] : ids.prefix(Self.groupCap)
            let hasMore = shown.count < ids.count
            for (i, id) in shown.enumerated() {
                guard let r = frozen.results[id] else { continue }
                let evidence = r.match != nil
                builder.add(.item(id), evidence ? .evidence(r) : .name(r), group,
                            evidence ? theme.evidenceContent : theme.nameContent,
                            first: i == 0, last: i == shown.count - 1 && !hasMore)
            }
            if hasMore {
                builder.add(.showAll(group), .showAll(group, ids.count), group, theme.nameContent, first: false, last: true)
            }
        }
        var message: ListMessage?
        if builder.rows.isEmpty {
            // Results subpath stays; the honest reason sits under the title, then the slip lands on "Search in Finder".
            message = ListMessage(title: "No matches for “\(query.trimmingCharacters(in: .whitespaces))”",
                                  detail: status.noResultsReason,
                                  footnote: rootsCount > 0 ? Self.footnote(rootsCount) : nil)
            builder.y = theme.messageContent
            builder.add(.finder, .finder(query), .files, theme.nameContent, first: true, last: true)
        } else if builder.rows.count == 1 {
            message = ListMessage(title: "1 match", detail: nil, footnote: nil)
        }
        commit(builder, message: message, keepSelection: keepSelection)
    }

    nonisolated static func footnote(_ roots: Int) -> String {
        "Searched \(roots.formatted()) \(roots == 1 ? "folder" : "folders") · Add folders in Settings (⌘,)"
    }

    private func commit(_ builder: RowBuilder, message: ListMessage?, keepSelection: Bool) {
        let oldScreenY = selectedRow.map { $0.y - scrollOffset }
        let oldID = selectedID
        let oldHeight = panelHeight
        defer { if panelHeight != oldHeight { onHeightChange?() } }
        rows = withText(builder.rows)
        contentHeight = builder.y
        self.message = message
        disarmHover()
        if keepSelection, let oldID, let row = rows.first(where: { $0.id == oldID }) {
            // Anchor by ID: an insert above the viewport shifts the offset by the inserted pitch in the same
            // transaction, so the slip and its cuts stay where they were on screen.
            if let oldScreenY { scrollOffset = clampOffset(row.y - oldScreenY) }
        } else {
            selectedID = rows.first?.id
            railIndex = 0
            scrollOffset = 0
        }
        scrollOffset = clampOffset(scrollOffset)
    }

    /// U6: title lines for the first screen of rows, built once per batch (memoised per query, so a content batch
    /// that keeps the name rows reuses them) instead of in every row body.
    @ObservationIgnored private var textMemo: (query: String, theme: Theme, byID: [UInt32: RowText]) = ("", .large, [:])

    private func withText(_ built: [Row]) -> [Row] {
        if textMemo.query != query || textMemo.theme != theme || textMemo.byID.count > 256 {
            textMemo = (query, theme, [:])
        }
        var out = built
        let limit = theme.resultsHeight
        for i in out.indices where out[i].y < limit {
            guard let result = out[i].result else { continue }
            if let hit = textMemo.byID[result.id] {
                out[i].text = hit
            } else {
                let text = RowText.make(result, query: query, theme: theme)
                textMemo.byID[result.id] = text
                out[i].text = text
            }
        }
        return out
    }

    // MARK: Selection

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
            || DebugOverrides.reduceMotion
    }

    /// One step: instant, no wrap (key repeat is never late).
    func move(_ delta: Int) {
        guard let index = selectedIndex else { return }
        select(index: min(max(index + delta, 0), rows.count - 1))
    }

    /// ⌥↑/⌥↓: first row of the previous/next group. Instant, like every slip move (D4).
    func jumpGroup(_ delta: Int) {
        guard let index = selectedIndex else { return }
        let group = rows[index].group
        if delta > 0 {
            guard let next = rows[index...].firstIndex(where: { $0.group != group }) else { return }
            select(index: next)
        } else {
            let startOfGroup = rows[..<index].lastIndex(where: { $0.group != group }).map { $0 + 1 } ?? 0
            if startOfGroup < index {
                select(index: startOfGroup)
            } else if startOfGroup > 0 {
                let prevGroup = rows[startOfGroup - 1].group
                let start = rows[..<startOfGroup].lastIndex(where: { $0.group != prevGroup }).map { $0 + 1 } ?? 0
                select(index: start)
            }
        }
    }

    /// ⌘↑/⌘↓.
    func jumpEnd(_ last: Bool) {
        guard !rows.isEmpty else { return }
        select(index: last ? rows.count - 1 : 0)
    }

    /// Click: moves the slip instantly, however far (D4).
    func click(_ id: RowID) {
        guard let target = rows.firstIndex(where: { $0.id == id }) else { return }
        select(index: target)
    }

    func clickRail(_ index: Int) {
        if selectedID != .rail { click(.rail) }
        railIndex = index
    }

    /// ←/→ on the favorites shelf. Returns false when the slip is not on it.
    func moveOnRail(_ delta: Int) -> Bool {
        guard let row = selectedRow, case .rail(let items) = row.content else { return false }
        railIndex = min(max(railIndex + delta, 0), items.count - 1)
        return true
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return rows.isEmpty ? nil : 0 }
        return rows.firstIndex { $0.id == selectedID } ?? 0
    }

    /// D4/U17: every slip move is a plain assignment; the slip is at its destination on the first changed frame.
    private func select(index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        disarmHover()
        slipHint = nil
        chips = nil
        selectedID = row.id
        railIndex = 0
        // Keyboard-driven scroll keeps the slip visible: the offset is set instantly.
        if row.y < scrollOffset {
            scrollOffset = clampOffset(row.y)
        } else if row.y + row.height > scrollOffset + viewportHeight {
            scrollOffset = clampOffset(row.y + row.height + theme.seam - viewportHeight)
        }
    }

    // MARK: Scrolling

    func scroll(by delta: CGFloat) {
        guard maxOffset > 0 else { return }
        let next = clampOffset(scrollOffset - delta)
        guard next != scrollOffset else { return }
        scrollOffset = next
        showScroller()
    }

    func scroll(to offset: CGFloat) {
        scrollOffset = clampOffset(offset)
        showScroller()
    }

    private func clampOffset(_ value: CGFloat) -> CGFloat {
        min(max(0, value.rounded()), maxOffset)
    }

    private func showScroller() {
        scrollerVisible = true
        scrollerTask?.cancel()
        scrollerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if self.reducesMotion {
                self.scrollerVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.18)) { self.scrollerVisible = false }
            }
        }
    }

    // MARK: Hover (never moves the slip; armed only by ≥ 3 pt of real pointer movement)

    func hover(_ id: RowID?, rail: Int? = nil) {
        let location = NSEvent.mouseLocation
        if let anchor = hoverAnchor {
            guard hypot(location.x - anchor.x, location.y - anchor.y) >= 3 else { return }
            hoverAnchor = nil
        }
        if hoveredID != id { hoveredID = id }
        if railHover != rail { railHover = rail }
    }

    func endHover(_ id: RowID) {
        if hoveredID == id {
            hoveredID = nil
            railHover = nil
        }
    }

    private func disarmHover() {
        hoverAnchor = NSEvent.mouseLocation
    }

    #if DEBUG
    /// `BS_HOVER_ROW=n`: show the hover state on row n for screenshots, bypassing the pointer-movement arm.
    func hoverForDebug(row n: Int) {
        guard rows.indices.contains(n) else { return }
        hoverAnchor = nil
        hoveredID = rows[n].id
    }
    #endif

    // MARK: Narrowing, expansion, chips, hints

    /// Tab: keep only results of the slip's kind. Returns false when there is nothing to narrow.
    func narrowToSelection() -> Bool {
        guard narrowed == nil, let row = selectedRow, row.group != .favorites, row.group != .recents,
              row.id != .finder else { return false }
        let group = row.group == .topHit ? (row.result?.naturalGroup ?? .files) : row.group
        narrowed = group
        rebuild(keepSelection: true)
        status.flash("Showing \(group.noun.lowercased()) only")
        return true
    }

    func widen() -> Bool {
        guard narrowed != nil else { return false }
        narrowed = nil
        rebuild(keepSelection: true)
        return true
    }

    func expand(_ group: DisplayGroup) {
        let firstHidden = (frozen.order[group] ?? []).dropFirst(Self.groupCap).first
        expanded.insert(group)
        rebuild(keepSelection: true)
        if let firstHidden, let index = rows.firstIndex(where: { $0.id == .item(firstHidden) }) {
            select(index: index)
        }
    }

    func openChips(_ actions: [PanelAction], focus: Int = 0, chooser: Bool = false) {
        guard !actions.isEmpty else { return }
        let state = ChipState(actions: actions, focus: min(focus, actions.count - 1), isChooser: chooser)
        if reducesMotion || chips != nil {
            chips = state
        } else {
            withAnimation(.spring(duration: 0.14, bounce: 0)) { chips = state }
        }
    }

    func closeChips() {
        guard chips != nil else { return }
        if reducesMotion { chips = nil } else { withAnimation(.spring(duration: 0.14, bounce: 0)) { chips = nil } }
    }

    func focusChip(_ delta: Int) {
        guard var state = chips else { return }
        state.focus = min(max(state.focus + delta, 0), state.actions.count - 1)
        chips = state
    }

    func setSlipHint(_ text: String?) { slipHint = text }

    func setCommandHeld(_ held: Bool) {
        if held != commandHeld { commandHeld = held }
    }

    /// The row shown at slot `n` (1-based) of the viewport, for ⌘1…⌘8; favorites on the empty query.
    func slotTarget(_ n: Int) -> SearchResult? {
        if isEmptyQuery {
            return favorites.indices.contains(n - 1) ? favorites[n - 1] : nil
        }
        let visible = rows.filter { $0.y + $0.height > scrollOffset && $0.result != nil }
        return visible.indices.contains(n - 1) ? visible[n - 1].result : nil
    }

    /// Slot number shown in the gutter for a row while ⌘ is held.
    /// ⌘-digit slots of the first 8 visible result rows, computed once per list pass (U4).
    func slots() -> [RowID: Int] {
        guard commandHeld, !isEmptyQuery else { return [:] }
        var out: [RowID: Int] = [:]
        for r in rows where r.y + r.height > scrollOffset && r.result != nil {
            out[r.id] = out.count + 1
            if out.count == 8 { break }
        }
        return out
    }

    func slot(for row: Row) -> Int? {
        guard commandHeld, !isEmptyQuery, row.result != nil else { return nil }
        let visible = rows.filter { $0.y + $0.height > scrollOffset && $0.result != nil }
        guard let i = visible.firstIndex(where: { $0.id == row.id }), i < 8 else { return nil }
        return i + 1
    }
}

/// Lays rows out at fixed pitches: content height + one 4 pt lane.
private struct RowBuilder {
    let theme: Theme
    var rows: [Row] = []
    var y: CGFloat = 0

    init(theme: Theme) {
        self.theme = theme
    }

    mutating func add(_ id: RowID, _ content: Row.Content, _ group: DisplayGroup, _ height: CGFloat,
                      first: Bool, last: Bool) {
        rows.append(Row(id: id, content: content, group: group, y: y, height: height,
                        isFirstInGroup: first, isLastInGroup: last, text: nil))
        y += height + theme.seam
    }
}

/// The band status: one quiet line, ≤ 2 updates per second, transient confirmations first.
@MainActor
@Observable
final class StatusModel {
    private(set) var transient: String?
    private(set) var index: IndexStatus?
    private(set) var tiers: [ContentTierStatus] = []
    /// "Meaning search off" shows once per session.
    @ObservationIgnored private var shownModelMissing = false
    @ObservationIgnored private var modelMissingVisible = true
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var lastApply = ContinuousClock.now - .seconds(1)
    @ObservationIgnored private var pending: (IndexStatus, [ContentTierStatus])?
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    func flash(_ text: String) {
        transient = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled else { return }
            self.transient = nil
        }
    }

    /// Throttled to 2 Hz; the last value always lands.
    func update(_ status: IndexStatus, tiers: [ContentTierStatus]) {
        pending = (status, tiers)
        let elapsed = ContinuousClock.now - lastApply
        if elapsed >= .milliseconds(500) {
            applyPending()
        } else if applyTask == nil {
            applyTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500) - elapsed)
                self?.applyTask = nil
                self?.applyPending()
            }
        }
    }

    private func applyPending() {
        guard let (status, tiers) = pending else { return }
        pending = nil
        lastApply = .now
        if status != index { index = status }
        if tiers != self.tiers { self.tiers = tiers }
    }

    /// Called when the panel hides: the model-missing notice has been seen once.
    func panelDidHide() {
        if index?.phase == .modelMissing, modelMissingVisible { shownModelMissing = true }
    }

    /// The trailing text of the query band, or nil.
    var text: String? {
        if let transient { return transient }
        if let tier = tiers.first(where: { $0.done < $0.total }) {
            let pct = tier.total > 0 ? Int((Double(tier.done) / Double(tier.total) * 100).rounded(.down)) : 0
            switch tier.tier {
            case .documents: return "Reading documents \(pct)%"
            case .images: return "Reading text in images \(pct)%"
            case .speech: return "Transcribing \(tier.done.formatted()) of \(tier.total.formatted()) recordings"
            case .meaning: return "Indexing meaning \(pct)%"
            }
        }
        guard let index else { return nil }
        if index.phase == .idle, !index.unreadable.isEmpty { return Self.unreadableText(index.unreadable.count) }
        switch index.phase {
        case .crawling:
            return index.items > 0 ? "Reading \(index.items.formatted()) items" : "Reading folders…"
        case .embedding, .paused:
            return index.embedded < index.total
                ? "Indexing \(index.embedded.formatted()) of \(index.total.formatted())" : nil
        case .modelMissing:
            return shownModelMissing ? nil : "Meaning search is off. Set it up…"
        case .idle, .catchingUp, .verifying:
            // Journal replay and stat-only verify scans are quiet: results stay valid while they run.
            return nil
        }
    }

    /// Where a click on the status line goes (U11, §7).
    enum Route: Equatable { case settingsIndex, modelSetup }

    var route: Route {
        if transient == nil, tiers.allSatisfy({ $0.done >= $0.total }), index?.phase == .modelMissing { return .modelSetup }
        return .settingsIndex
    }

    /// True when the status line reports an error (gets the triangle, M2.5).
    var isError: Bool {
        guard transient == nil, let index, tiers.allSatisfy({ $0.done >= $0.total }) else { return false }
        return index.phase == .idle && !index.unreadable.isEmpty
    }

    nonisolated static func unreadableText(_ n: Int) -> String {
        n == 1 ? "1 folder can't be read" : "\(n.formatted()) folders can't be read"
    }

    /// The honest reason under "No matches".
    var noResultsReason: String? {
        if let tier = tiers.first(where: { $0.done < $0.total }) {
            let pct = tier.total > 0 ? Int(Double(tier.done) / Double(tier.total) * 100) : 0
            switch tier.tier {
            case .images: return "Still reading text in images · \(pct)%"
            case .documents: return "Still reading documents · \(pct)%"
            case .speech: return "Still transcribing recordings · \(pct)%"
            case .meaning: return "Meaning index \(pct)% done"
            }
        }
        if let index, index.phase == .crawling { return "Files become searchable as they're read." }
        return nil
    }

    /// Settings › Index line.
    var detail: String {
        guard let index else { return "Starting…" }
        var parts = ["\(index.items.formatted()) items"]
        switch index.phase {
        case .idle: parts.append("up to date")
        case .crawling: parts.append("reading folders")
        case .embedding: parts.append("\(index.embedded.formatted()) of \(index.total.formatted()) with meaning")
        case .paused: parts.append("paused while the panel is open")
        case .modelMissing: parts.append("meaning search is off")
        case .catchingUp: parts.append("catching up on changes")
        case .verifying: parts.append("checking folders for changes")
        }
        if index.cloudOnly > 0 { parts.append("\(index.cloudOnly.formatted()) only in iCloud") }
        for tier in tiers {
            let name = switch tier.tier {
            case .documents: "documents"
            case .images: "images"
            case .speech: "speech"
            case .meaning: "meaning"
            }
            parts.append("\(name) \(tier.done.formatted())/\(tier.total.formatted())")
        }
        return parts.joined(separator: " · ")
    }
}
