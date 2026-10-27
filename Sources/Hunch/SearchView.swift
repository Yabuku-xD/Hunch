import AppKit
import HunchCore
import SwiftUI

/// Seam: one slab of untinted `.regular` glass. The query is a band of the same slab; the selected row is a slip cut
/// out of it by two 4 pt lanes. Rows, text and thumbnails are the glass effect's content, never siblings over glass.
/// Nothing animates while typing; the panel shows and hides instantly.
struct SeamRoot: View {
    @Bindable var model: SearchModel
    let controller: PanelController
    @Namespace private var glass

    static let margin: CGFloat = 16

    var body: some View {
        let t = model.theme
        let chipCarve = model.chips.map { ChipMetrics.carve($0, theme: t) } ?? 0
        let slip = slipEdges
        ZStack(alignment: .topLeading) {
            // Clicks in the transparent margin (the glass draws its rim and shadow there) dismiss, like a click outside.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { controller.hide() }
            GlassEffectContainer(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    SeamContent(model: model, controller: controller, chipCarve: chipCarve)
                        .frame(width: t.slabWidth, height: model.panelHeight, alignment: .top)
                        .glassEffect(
                            .regular,
                            in: SeamPath(
                                width: t.slabWidth, band: t.bandHeight, seam: t.seam, height: model.panelHeight,
                                outer: t.outerRadius, cut: t.cutRadius, hasResults: model.hasResults,
                                hasSlip: slip != nil, slipTop: slip?.lowerBound ?? 0, slipBottom: slip?.upperBound ?? 0,
                                chipCarve: chipCarve, footer: model.footerHeight)
                        )
                        .glassEffectID("slab", in: glass)
                    if let chips = model.chips, let slip {
                        ChipStrip(state: chips, theme: t, namespace: glass) { controller.runChip($0) }
                            .padding(.top, ((slip.lowerBound + slip.upperBound) / 2 - t.chipHeight / 2).rounded())
                            .padding(.trailing, ChipMetrics.trailingInset)
                    }
                }
                .frame(width: t.slabWidth, height: model.panelHeight, alignment: .topLeading)
            }
            .padding(Self.margin)
            HoverWash(model: model)
                .frame(width: t.slabWidth, height: model.panelHeight, alignment: .topLeading)
                .padding(Self.margin)
                .allowsHitTesting(false)
        }
        .environment(\.layoutDirection, .leftToRight)
        .debugAccessibilityOverrides()
    }

    /// Slip edges in slab coordinates, scrolled; nil when nothing is selected or the list is hidden.
    private var slipEdges: ClosedRange<CGFloat>? {
        guard model.hasResults, let span = model.slipSpan else { return nil }
        let top = model.theme.bandHeight + model.theme.seam - model.scrollOffset
        return (span.lowerBound + top)...(span.upperBound + top)
    }
}

/// The glass's content: the query band, the permanent seam, the results.
private struct SeamContent: View {
    @Bindable var model: SearchModel
    let controller: PanelController
    let chipCarve: CGFloat

    var body: some View {
        let t = model.theme
        VStack(spacing: 0) {
            QueryBand(model: model, controller: controller)
                .frame(height: t.bandHeight)
            if model.hasResults {
                Color.clear.frame(height: t.seam)
                ResultsList(model: model, controller: controller, chipCarve: chipCarve)
                    .frame(width: t.slabWidth, height: model.viewportHeight, alignment: .topLeading)
                if model.showsFooter {
                    FooterLine(model: model, controller: controller)
                        .frame(width: t.slabWidth, height: t.footerHeight)
                }
            }
        }
    }
}

// MARK: Query band

private struct QueryBand: View {
    @Bindable var model: SearchModel
    let controller: PanelController
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    /// F23: the pin hint shows until the first pin.
    @AppStorage("hint.pin.seen", store: AppDefaults.store) private var pinHintSeen = false

    var body: some View {
        let t = model.theme
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: t.magnifierSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: t.leading)
                .padding(.leading, t.padding + t.gutter)
                .accessibilityHidden(true)
            Color.clear.frame(width: t.iconGap)
            TextField(
                "Search",
                text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                // P21: no prompt under an input method's marked text (same look otherwise).
                prompt: Text(model.isComposing ? "" : "Apps, files and what's inside them")
                    .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: t.querySize))
            .foregroundStyle(.primary)
            .focused($focused)
            .accessibilityLabel("Search apps, files and folders")
            trailing
                .padding(.trailing, t.padding + 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .onChange(of: model.selectAllToken) {
            focused = true
            DispatchQueue.main.async { controller.selectAllInField() }
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if let narrowed = model.narrowed {
                HStack(spacing: 4) {
                    GroupGlyph(group: narrowed, size: 11)
                    Text("only")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Showing \(narrowed.noun.lowercased()) only")
            }
            if model.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Searching")
            }
            if !model.showsFooter, let text = model.status.text {
                Button {
                    controller.statusClicked()
                } label: {
                    StatusLabel(text: text, isError: model.status.isError, size: 12)
                }
                .buttonStyle(QuietButtonStyle(id: "band.status"))
                .fixedSize()
                .help("Index status. Click for details.")
                .accessibilityLabel("Index status")
                .accessibilityValue(text)
                .accessibilityHint("Opens Settings")
            } else if model.isEmptyQuery, !model.hasResults, !pinHintSeen {
                HStack(spacing: 6) {
                    Text("Pin with").font(.system(size: 12)).foregroundStyle(.tertiary)
                    KeyCaps(caps: ["⌘", "⇧", "P"])
                }
            }
        }
    }
}

// MARK: Footer

/// The slab's last section, part of the same glass: index status on the left, the selection's primary action and ⌘K
/// on the right. No bar, no fill, no divider; the list dissolves into it.
private struct FooterLine: View {
    @Bindable var model: SearchModel
    let controller: PanelController

    var body: some View {
        let t = model.theme
        HStack(spacing: 14) {
            if let text = model.status.text {
                Button {
                    controller.statusClicked()
                } label: {
                    StatusLabel(text: text, isError: model.status.isError, size: t.footerSize)
                }
                .buttonStyle(QuietButtonStyle(id: "footer.status"))
                .help("Index status. Click for details.")
                .accessibilityLabel("Index status")
                .accessibilityValue(text)
                .accessibilityHint("Opens Settings")
            }
            Spacer(minLength: 8)
            // U9/F13: the slip already names its verb + ↵; the footer repeats it only when the slip is scrolled away.
            if model.selectedRow != nil, !slipOnScreen, !model.primaryVerb.isEmpty {
                Button {
                    controller.activate()
                } label: {
                    ActionHint(verb: model.primaryVerb)
                }
                .buttonStyle(QuietButtonStyle(id: "footer.verb"))
                .accessibilityLabel(model.primaryVerb)
            }
            if model.selectedResult != nil {
                Button {
                    controller.toggleChips()
                } label: {
                    ActionHint(verb: "Actions", caps: ["⌘", "K"])
                }
                .buttonStyle(QuietButtonStyle(id: "footer.actions"))
                .accessibilityLabel("Actions")
            }
        }
        .padding(.leading, t.titleStart)
        .padding(.trailing, t.padding + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Same visibility test the rows use for the slip's trailing verb (`visibleRows`), no extra state.
    private var slipOnScreen: Bool {
        guard let id = model.selectedID else { return false }
        return model.visibleRows.contains { $0.id == id }
    }
}

// MARK: Results

/// What the slip shows at its trailing end: an override hint ("No longer exists") or the primary verb + ↵.
enum SlipTrailing: Equatable {
    case none
    case hint(String)
    case verb(String)
}

private struct ResultsList: View {
    @Bindable var model: SearchModel
    let controller: PanelController
    let chipCarve: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let t = model.theme
        let offset = model.scrollOffset
        let hiddenBelow = model.maxOffset - offset
        // U4: everything a row shows is read here once and handed down as plain values. Rows are `Equatable` and
        // observe nothing of the model, so a ⌘ press, a slip move or an appended batch re-renders only the rows whose
        // values changed (⌘: the gutters, slip move: 2 rows), never the whole list. A hover re-renders no row
        // (`HoverWash`).
        let slots = model.slots()
        let selected = model.selectedID
        let query = model.query
        let underline = contrast == .increased
        let visible = model.visibleRows
        // The slip's verb needs a LaunchServices lookup for files; only when the slip is on screen.
        let slipTrailing: SlipTrailing =
            visible.contains { $0.id == selected }
            ? (model.slipHint.map(SlipTrailing.hint) ?? .verb(model.primaryVerb)) : .none
        ZStack(alignment: .topLeading) {
            if let message = model.message {
                messageView(message)
            }
            // Keyed by a ring slot (row index mod 24 > the most rows a viewport can hold), not by result. A keystroke that
            // replaces every result then updates the existing row subgraphs instead of tearing them down and building
            // new ones (≈ 30% less layout on the swap; keying by result id measured +60% commit), and while scrolling a
            // row keeps its slot, so only the row that enters is rebuilt. Rows hold no view state; hover and selection
            // live in the model by RowID.
            ForEach(visible.indices.map { (slot: $0 % 24, row: visible[$0]) }, id: \.slot) { _, row in
                let isSlip = selected == row.id
                RowView(
                    row: row, theme: t, query: query, underline: underline, isSlip: isSlip, slot: slots[row.id],
                    carve: isSlip ? chipCarve : 0, trailing: isSlip ? slipTrailing : .none, controller: controller
                )
                .equatable()
                .frame(width: t.slabWidth, height: row.height)
                // The ZStack places each row by its top-leading guides; stating them here stops that query from
                // walking down every row's stacks for an explicit guide on each update (≈ 20% of the commit).
                .alignmentGuide(.top) { _ in 0 }
                .alignmentGuide(.leading) { _ in 0 }
                .offset(y: row.y - offset)
            }
        }
        .frame(width: t.slabWidth, height: model.viewportHeight, alignment: .topLeading)
        // One hover and one click handler for the whole list (hit-tested by row geometry) instead of three gesture
        // modifiers per row; the favorites cells keep their own, which win over these.
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                if let row = row(at: point.y) {
                    // The shelf's cells report which favorite is hovered; the row only claims the shelf.
                    if row.id != .rail || model.hoveredID != .rail { model.hover(row.id) }
                } else if let id = model.hoveredID {
                    model.endHover(id)
                }
            case .ended:
                if let id = model.hoveredID { model.endHover(id) }
            }
        }
        .onTapGesture { point in
            if let row = row(at: point.y) { controller.click(row) }
        }
        .clipped()
        .mask {
            // Bottom edge dissolve: a luminance mask, eased by how much is hidden below (never a colour overlay).
            VStack(spacing: 0) {
                Rectangle()
                // Fully clear at the edge: a row cut by the viewport never shows a hard slice through its glyphs.
                LinearGradient(
                    colors: [.black, .black.opacity(hiddenBelow > 1 ? 0 : 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 32)
            }
        }
        .overlay(alignment: .topTrailing) { scroller }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
    }

    /// The row whose content box (not its lane) is under a point of the viewport.
    private func row(at viewportY: CGFloat) -> Row? {
        let y = viewportY + model.scrollOffset
        return model.visibleRows.first { y >= $0.y && y < $0.y + $0.height }
    }

    @ViewBuilder private func messageView(_ message: ListMessage) -> some View {
        let t = model.theme
        if model.isNoResults {
            VStack(spacing: 4) {
                Text(message.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = message.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(
                        contrast == .increased ? .secondary : .tertiary)
                }
                if let footnote = message.footnote {
                    Button {
                        controller.openSettings(.search)
                    } label: {
                        Text(footnote).font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                    }
                    .buttonStyle(QuietButtonStyle(id: "message.footnote"))
                    .accessibilityHint("Opens Settings")
                }
            }
            .padding(.horizontal, t.titleStart)
            .frame(width: t.slabWidth, height: t.messageContent - t.seam)
            .offset(y: -model.scrollOffset)
        } else {
            Text(message.title)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, t.titleStart)
                .frame(height: 24)
                .offset(y: model.contentHeight - model.scrollOffset)
        }
    }

    /// Thin overlay scroller: 3 pt, shown while scrolling, fades 0.8 s after the last scroll.
    @ViewBuilder private var scroller: some View {
        let viewport = model.viewportHeight
        let total = model.totalHeight
        if total > viewport + 1 {
            let thumb = max(28, viewport * viewport / total)
            let y = model.maxOffset > 0 ? model.scrollOffset / model.maxOffset * (viewport - thumb) : 0
            Capsule()
                .fill(Color.primary.opacity(0.28))
                .frame(width: 3, height: thumb)
                .offset(x: -3, y: y)
                .opacity(model.scrollerVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: Rows

/// Hover: a quiet fill over the hovered row's content box. It never moves the slip and never cuts the glass.
/// It is a sibling drawn over the glass container, not part of the glass content: a filled shape inside glass content
/// made the renderer keep a panel-sized surface per hovered row (about 16 MB each, 115 MB after five rows, freed only
/// on hide), and inside the container (outside the content) it did not draw at all. The AppKit quaternary fill as a
/// plain colour; the `.fill.quaternary` shape style renders louder than the slip.
private struct HoverWash: View {
    let model: SearchModel

    var body: some View {
        let t = model.theme
        if let id = model.hoveredID, id != model.selectedID, id != .rail,
            let row = model.visibleRows.first(where: { $0.id == id })
        {
            let top = t.bandHeight + t.seam
            let y = row.y - model.scrollOffset
            let visibleTop = max(y, 0), visibleBottom = min(y + row.height, model.viewportHeight)
            if visibleBottom > visibleTop {
                Color(nsColor: .quaternarySystemFill)
                    .clipShape(RoundedRectangle(cornerRadius: t.cutRadius, style: .continuous))
                    .frame(width: t.slabWidth - 8, height: row.height)
                    .offset(x: 4, y: y)
                    .frame(width: t.slabWidth, height: model.viewportHeight, alignment: .topLeading)
                    .clipped()
                    .offset(y: top)
            }
        }
    }
}

/// One result slot. Takes plain values only (U4) and is compared before its body runs (`.equatable()`); the rail
/// row is the one exception that reads the model, through its own `FavoritesRail` view.
private struct RowView: View, Equatable {
    let row: Row
    let theme: Theme
    let query: String
    let underline: Bool
    let isSlip: Bool
    let slot: Int?
    let carve: CGFloat
    let trailing: SlipTrailing
    /// Actions only; not compared.
    let controller: PanelController

    nonisolated static func == (a: RowView, b: RowView) -> Bool {
        a.isSlip == b.isSlip && a.slot == b.slot && a.carve == b.carve
            && a.trailing == b.trailing && a.underline == b.underline && a.theme == b.theme
            && a.row.id == b.row.id && a.row.group == b.row.group && a.row.height == b.row.height
            && a.row.isFirstInGroup == b.row.isFirstInGroup && a.row.isLastInGroup == b.row.isLastInGroup
            && Row.sameContent(a.row.content, b.row.content)
            && (a.query == b.query || a.row.result == nil)
    }

    var body: some View {
        let t = theme
        HStack(spacing: 0) {
            Gutter(row: row, slot: slot, theme: t)
            content
        }
        .padding(.leading, t.padding)
        .padding(.trailing, t.padding + carve)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

    }

    @ViewBuilder private var content: some View {
        let t = theme
        let chipsOpen = carve > 0
        switch row.content {
        case .name(let result):
            let text = text(result)
            HStack(spacing: 0) {
                Leading(result: result, theme: t, evidence: false)
                Color.clear.frame(width: t.iconGap)
                TitleLine(result: result, text: text, theme: t, isSlip: isSlip)
                Spacer(minLength: 10)
                Trailing(kind: text.kind, theme: t, isSlip: isSlip, chipsOpen: chipsOpen, slip: trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(result, group: row.group))
            .accessibilityAddTraits(isSlip ? [.isSelected, .isButton] : .isButton)
        case .evidence(let result):
            EvidenceLines(
                result: result, text: text(result), theme: t, isSlip: isSlip, chipsOpen: chipsOpen,
                underline: underline, slip: trailing
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(result, group: row.group))
            .accessibilityAddTraits(isSlip ? [.isSelected, .isButton] : .isButton)
        case .rail(let items):
            FavoritesRail(model: controller.model, controller: controller, items: items, isSlip: isSlip)
        case .showAll(let group, let count):
            HStack(spacing: 0) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: t.leading)
                Color.clear.frame(width: t.iconGap)
                Text("Show all \(DisplayText.count(count)) \(group.noun)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if isSlip { ActionHint(verb: "Show All") }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        case .finder(let query):
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: t.leading)
                Color.clear.frame(width: t.iconGap)
                Text("Search in Finder for “\(query.trimmingCharacters(in: .whitespaces))”")
                    .font(.system(size: t.titleSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                ActionHint(verb: isSlip ? "Search" : "", caps: isSlip ? ["↵"] : ["⌘", "↵"])
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    /// The batch-built title line (U6); rows below the first screen and Increase Contrast build it here.
    private func text(_ result: SearchResult) -> RowText {
        if let text = row.text, !underline { return text }
        return RowText.make(result, query: query, theme: theme, underline: underline)
    }

    static func spoken(_ result: SearchResult, group: DisplayGroup) -> String {
        var parts = [DisplayText.name(result.item)]
        if group == .topHit { parts.insert("Top Hit", at: 0) }
        parts.append(KindLabel.text(for: result.item))
        if let location = DisplayText.locations(result.item).first { parts.append(location) }
        if result.item.kind == .app, RunningApps.shared.isRunning(result.item.path) { parts.append("running") }
        if let evidence = DisplayText.spokenEvidence(result) { parts.append(evidence) }
        return parts.joined(separator: ", ")
    }
}

extension Row {
    /// Whether two rows show the same thing (the `RowView` comparison; the score is never shown).
    nonisolated static func sameContent(_ a: Content, _ b: Content) -> Bool {
        switch (a, b) {
        case (.name(let x), .name(let y)), (.evidence(let x), .evidence(let y)):
            return same(x, y)
        case (.rail(let x), .rail(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case (.showAll(let g, let n), .showAll(let h, let m)):
            return g == h && n == m
        case (.finder(let q), .finder(let r)):
            return q == r
        default:
            return false
        }
    }

    nonisolated private static func same(_ x: SearchResult, _ y: SearchResult) -> Bool {
        x.item == y.item && x.source == y.source && x.match == y.match && x.moreMatches == y.moreMatches
    }
}

/// Group glyph once per group, a hairline spanning the group, or the ⌘-slot cap while ⌘ is held.
private struct Gutter: View {
    let row: Row
    let slot: Int?
    let theme: Theme

    var body: some View {
        ZStack(alignment: .top) {
            if row.group != .favorites {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 0.5)
                    .padding(.top, row.isFirstInGroup ? row.height / 2 + 12 : 0)
                    .padding(.bottom, row.isLastInGroup ? 6 : 0)
                    .frame(maxHeight: .infinity)
            }
            // Centred on the row's icon tile (rows centre their content vertically).
            if let slot {
                KeyCap("\(slot)", size: 10)
                    .frame(width: theme.gutter, height: row.height)
            } else if row.isFirstInGroup {
                GroupGlyph(group: row.group, size: 12)
                    .foregroundStyle(.tertiary)
                    .frame(width: theme.gutter, height: row.height)
                    .accessibilityLabel(row.group.title)
            }
        }
        .frame(width: theme.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct GroupGlyph: View {
    let group: DisplayGroup
    let size: CGFloat

    var body: some View {
        // One square box per glyph, so wide symbols (photo, waveform) and the ≈ sign share one centre and size.
        Group {
            if group.isMeaning {
                Text("≈").font(.system(size: size + 2, weight: .semibold))
            } else {
                Image(systemName: group.symbol)
                    .resizable()
                    .fontWeight(.medium)
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size + 4, height: size + 4)
    }
}

/// Icon (with the running-app dot) or proof crop, in the fixed leading column. U3: it observes only its own
/// `IconSlot`/`ProofSlot`, so an arriving icon re-renders this one view, not the list.
private struct Leading: View {
    let result: SearchResult
    let theme: Theme
    let evidence: Bool

    var body: some View {
        let wantsProof = evidence && ProofCache.wantsProof(result)
        // Getting a slot starts its off-main load once; the arrival lands on the slot later, never in this pass.
        let icon = IconCache.shared.slot(for: result.item)
        let proof =
            wantsProof
            ? ProofCache.shared.slot(for: result, points: theme.proof, scale: DisplayScale.current)
            : nil
        return ZStack {
            if let image = proof?.image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: theme.proof, height: theme.proof)
                    .overlay(alignment: .bottomTrailing) { timeCaption }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    // Flattened to pixels: as glass content the scrim was re-inked by the dark slab's vibrancy and
                    // nearly vanished on bright frames. Rasterised, it composites like the frame itself.
                    .drawingGroup()
            } else if let image = icon.image {
                Image(decorative: image, scale: DisplayScale.current)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: theme.icon, height: theme.icon)
            } else {
                Color.clear.frame(width: theme.icon, height: theme.icon)
            }
            if result.item.kind == .app, RunningApps.shared.isRunning(result.item.path) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .offset(y: theme.icon / 2 + 2)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: theme.leading, height: theme.icon)
        .accessibilityHidden(true)
    }

    /// Video proofs carry their timecode inside the frame.
    @ViewBuilder private var timeCaption: some View {
        if let time = result.match?.location.time, FileKind.of(result.item.path) == .video {
            Text(DisplayText.timecode(time))
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                // Media caption: it sits on arbitrary frame pixels, not on glass, so it is a fixed scrim chip
                // (the video-player convention) in both appearances, never an adaptive ink.
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(2)
        }
    }
}

/// Title (matched characters by weight) + dimmed `~` location on the same baseline.
private struct TitleLine: View {
    let result: SearchResult
    let text: RowText
    let theme: Theme
    let isSlip: Bool

    var body: some View {
        let t = theme
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(result.item.name)
            let locations = text.locations
            if !locations.isEmpty {
                Group {
                    if isSlip {
                        // The slip's trailing verb has no cheap width; let SwiftUI pick (one row only).
                        ViewThatFits(in: .horizontal) {
                            ForEach(locations, id: \.self) { location in
                                Text(location).lineLimit(1).fixedSize()
                            }
                            // Head-truncated only while it can keep ≥ 48 pt; below that a lone "…" stub would sit
                            // after the title (seen with a long name + chips open), so the location drops out
                            // instead. VoiceOver still reads it from the row label.
                            Text(locations.last ?? "").lineLimit(1).truncationMode(.head)
                                .frame(minWidth: 48, idealWidth: 48, maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 0, height: 0)
                        }
                    } else {
                        // Other rows: pick the longest location that fits from cached text widths. Same result as
                        // ViewThatFits without building and measuring four Texts per row on every keystroke.
                        if let location = text.location {
                            Text(location).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .font(.system(size: t.locationSize))
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Width arithmetic for a non-slip row's title line, from the Theme tokens and memoised CoreText widths.
@MainActor
enum LocationFit {
    private static var widths: [String: CGFloat] = [:]

    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let key = "\(size)|\(weight.rawValue)|\(text)"
        if let hit = widths[key] { return hit }
        if widths.count > 4_000 { widths.removeAll(keepingCapacity: true) }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[key] = w
        return w
    }

    static func choose(_ locations: [String], result: SearchResult, theme t: Theme) -> String? {
        var budget = t.slabWidth - 2 * t.padding - t.gutter - t.leading - t.iconGap - 10
        if t.showsKindColumn {
            budget -= min(150, width(KindLabel.text(for: result.item), size: 12, weight: .regular))
        }
        // Semibold is the widest weight a title run can take, so this never overestimates the room.
        budget -= width(DisplayText.name(result.item), size: t.titleSize, weight: .semibold) + 8
        if let fit = locations.first(where: { width($0, size: t.locationSize, weight: .regular) <= budget }) {
            return fit
        }
        // Not even the shortest fits: head-truncate it, unless that would leave a clipped stub like "~," (then the
        // VoiceOver label still reads the location).
        return budget >= 48 ? (locations.last ?? "") : nil
    }
}

private struct EvidenceLines: View {
    let result: SearchResult
    let text: RowText
    let theme: Theme
    let isSlip: Bool
    let chipsOpen: Bool
    let underline: Bool
    let slip: SlipTrailing

    var body: some View {
        let t = theme
        HStack(spacing: 0) {
            Leading(result: result, theme: t, evidence: true)
            Color.clear.frame(width: t.iconGap)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    TitleLine(result: result, text: text, theme: t, isSlip: isSlip)
                    Spacer(minLength: 10)
                    Trailing(kind: text.kind, theme: t, isSlip: isSlip, chipsOpen: chipsOpen, slip: slip)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(MatchHighlight.snippet(result, size: t.evidenceSize, underline: underline))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 10)
                    if let locator = DisplayText.locator(result), !chipsOpen {
                        Text(locator)
                            .font(.system(size: t.locatorSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// Kind label (tertiary) on ordinary rows; the primary verb + ↵ inside the slip.
private struct Trailing: View {
    let kind: String
    let theme: Theme
    let isSlip: Bool
    let chipsOpen: Bool
    let slip: SlipTrailing

    var body: some View {
        if chipsOpen {
            EmptyView()
        } else if isSlip {
            switch slip {
            case .hint(let hint):
                Text(hint).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            case .verb(let verb):
                ActionHint(verb: verb)
            case .none:
                ActionHint(verb: "")
            }
        } else if theme.showsKindColumn {
            Text(kind)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Empty query: up to 8 pinned items as large icons. ←/→ move along it while the slip is on it.
private struct FavoritesRail: View {
    let model: SearchModel
    let controller: PanelController
    let items: [SearchResult]
    let isSlip: Bool

    var body: some View {
        let icons = IconCache.shared
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, result in
                cell(result, index: index, icon: icons.slot(for: result.item).image)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favorites")
    }

    private func cell(_ result: SearchResult, index: Int, icon: CGImage?) -> some View {
        let focused = isSlip && model.railIndex == index
        let hovered = model.railHover == index && model.hoveredID == .rail
        let missing = model.railMissing.contains(result.id)
        return VStack(spacing: 4) {
            ZStack {
                if let icon {
                    Image(decorative: icon, scale: DisplayScale.current).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 48, height: 48)
            .opacity(missing ? 0.35 : 1)
            if model.commandHeld, index < 8 {
                KeyCap("\(index + 1)", size: 10)
            } else {
                Text(missing ? "Missing" : DisplayText.name(result.item))
                    .font(.system(size: 11, weight: focused ? .medium : .regular))
                    .foregroundStyle(focused ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: 72)
            }
        }
        .frame(width: 80, height: model.theme.railContent - 6)
        .background {
            if focused || hovered {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(focused ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: model.hover(.rail, rail: index)
            case .ended: break
            }
        }
        .onTapGesture { controller.clickRail(index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DisplayText.name(result.item))
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: ⌘K chips

enum ChipMetrics {
    static let spacing: CGFloat = 4
    static let gap: CGFloat = 4
    static let trailingInset: CGFloat = 2

    @MainActor
    static func width(_ action: PanelAction, focused: Bool, theme: Theme) -> CGFloat {
        guard focused else { return theme.chipHeight }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = (action.title as NSString).size(withAttributes: [.font: font]).width
        return (10 + 16 + 6 + text.rounded(.up) + 12).rounded(.up)
    }

    /// Width carved from the slip's trailing end: the chips plus a 4 pt gap, so glass never overlaps glass.
    @MainActor
    static func carve(_ state: ChipState, theme: Theme) -> CGFloat {
        let widths = state.actions.enumerated().map { width($1, focused: $0 == state.focus, theme: theme) }
        return widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)) + gap + trailingInset
    }
}

private struct ChipStrip: View {
    let state: ChipState
    let theme: Theme
    let namespace: Namespace.ID
    let run: (PanelAction) -> Void

    var body: some View {
        HStack(spacing: ChipMetrics.spacing) {
            ForEach(Array(state.actions.enumerated()), id: \.element.id) { index, action in
                chip(action, focused: index == state.focus, held: DebugOverrides.press == "chip:\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private func chip(_ action: PanelAction, focused: Bool, held: Bool) -> some View {
        Button {
            run(action)
        } label: {
            HStack(spacing: 6) {
                symbol(action)
                if focused {
                    Text(MatchHighlight.mnemonic(action.title, letter: action.mnemonic))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(focused ? .primary : .secondary)
            .frame(width: ChipMetrics.width(action, focused: focused, theme: theme), height: theme.chipHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(ChipPressStyle(heldForDebug: held))
        .glassEffect(.regular, in: Capsule())
        .glassEffectID(action.id, in: namespace)
        .glassEffectTransition(.materialize)
        .help(action.title + (action.keycaps.isEmpty ? "" : "  " + action.keycaps.joined()))
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private func symbol(_ action: PanelAction) -> some View {
        if case .openIn(let url) = action {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: action.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 16)
        }
    }
}

// MARK: Highlighting

/// Emphasis by weight only (no colour, no background). Under Increase Contrast matches are also underlined.
enum MatchHighlight {
    /// Title 14 medium; matched characters semibold. FSI…PDI isolates RTL names so the row keeps its order.
    static func title(_ name: String, query: String, size: CGFloat, underline: Bool) -> AttributedString {
        let matched = matchedIndices(name, query: query.trimmingCharacters(in: .whitespaces))
        var output = AttributedString("\u{2068}")
        output.font = .system(size: size, weight: .medium)
        var run = ""
        var runMatched = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.font = .system(size: size, weight: runMatched ? .semibold : .medium)
            if runMatched, underline { piece.underlineStyle = .single }
            output += piece
            run = ""
        }
        var index = 0
        for character in name {
            let isMatch = matched.contains(index)
            if isMatch != runMatched { flush(); runMatched = isMatch }
            run.append(character)
            index += 1
        }
        flush()
        var tail = AttributedString("\u{2069}")
        tail.font = .system(size: size, weight: .medium)
        output += tail
        return output
    }

    /// Snippet 12.5 `.secondary`, matched words semibold `.primary`. Starts near the first match so it survives
    /// tail truncation; meaning matches show the chunk plainly.
    static func snippet(_ result: SearchResult, size: CGFloat, underline: Bool) -> AttributedString {
        guard let match = result.match else {
            var plain = AttributedString(result.source == .semantic ? "Similar in meaning" : "")
            plain.font = .system(size: size)
            plain.foregroundColor = .secondary
            return plain
        }
        let text = DisplayText.sanitize(match.snippet)
        let utf16 = Array(text.utf16)
        var highlights = match.highlights
            .map { max(0, $0.lowerBound)..<min(utf16.count, $0.upperBound) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var start = 0
        if let first = highlights.first, first.lowerBound > 40 {
            // Re-centre on the first match at a word boundary.
            var cut = first.lowerBound - 30
            while cut < first.lowerBound, let scalar = UnicodeScalar(utf16[cut]),
                !CharacterSet.whitespaces.contains(scalar)
            {
                cut += 1
            }
            start = cut
        }
        highlights = highlights.map { ($0.lowerBound - start)..<($0.upperBound - start) }
        let body = String(utf16CodeUnits: Array(utf16[start...]), count: utf16.count - start)
        var output = AttributedString(start > 0 ? "…\u{2068}" : "\u{2068}")
        output.font = .system(size: size)
        output.foregroundColor = .secondary
        let units = Array(body.utf16)
        var cursor = 0
        func append(_ range: Range<Int>, matched: Bool) {
            guard !range.isEmpty, range.upperBound <= units.count else { return }
            var piece = AttributedString(String(utf16CodeUnits: Array(units[range]), count: range.count))
            piece.font = .system(size: size, weight: matched ? .semibold : .regular)
            piece.foregroundColor = matched ? .primary : .secondary
            if matched, underline { piece.underlineStyle = .single }
            output += piece
        }
        for h in highlights where h.lowerBound >= cursor {
            append(cursor..<h.lowerBound, matched: false)
            append(h, matched: true)
            cursor = h.upperBound
        }
        append(cursor..<units.count, matched: false)
        var tail = AttributedString("\u{2069}")
        tail.font = .system(size: size)
        output += tail
        return output
    }

    /// The chip label with its mnemonic letter underlined.
    static func mnemonic(_ title: String, letter: Character?) -> AttributedString {
        var output = AttributedString(title)
        guard let letter, let range = output.range(of: String(letter), options: .caseInsensitive) else { return output }
        output[range].underlineStyle = .single
        return output
    }

    /// Indices (in Characters) of the name that match: contiguous first (case/diacritic-insensitive), else an
    /// in-order subsequence. Grapheme-safe: works on Characters, never splits a cluster.
    static func matchedIndices(_ name: String, query: String) -> Set<Int> {
        guard !query.isEmpty else { return [] }
        let chars = Array(name)
        if let range = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = name.distance(from: name.startIndex, to: range.lowerBound)
            let length = name.distance(from: range.lowerBound, to: range.upperBound)
            return Set(start..<(start + length))
        }
        var result = Set<Int>()
        var cursor = 0
        for q in query where !q.isWhitespace {
            guard
                let found = chars[cursor...].firstIndex(where: {
                    String($0).compare(String(q), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                })
            else { return [] }
            result.insert(found)
            cursor = found + 1
        }
        return result
    }
}
