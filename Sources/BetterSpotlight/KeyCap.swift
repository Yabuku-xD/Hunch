import SwiftUI

/// One key glyph on a quiet `.fill.quaternary` cap (radius 5). Reused by the slip hint, slot caps, chips and Settings.
struct KeyCap: View {
    let label: String
    var size: CGFloat = 11

    init(_ label: String, size: CGFloat = 11) {
        self.label = label
        self.size = size
    }

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: size + 7, minHeight: size + 7)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A chord as a row of keycaps.
struct KeyCaps: View {
    let caps: [String]
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in KeyCap(cap, size: size) }
        }
    }
}

/// "Open in Preview ↵": the primary verb named inside the slip.
struct ActionHint: View {
    let verb: String
    var caps: [String] = ["↵"]
    @Environment(\.quietHover) private var hover

    var body: some View {
        HStack(spacing: 6) {
            Text(verb)
                .font(.system(size: 12))
                .foregroundStyle(hover ? .primary : .secondary)
                .lineLimit(1)
            KeyCaps(caps: caps)
        }
        .fixedSize()
    }
}

/// The band/footer status text; an error state adds a triangle (never colour alone, M2.5).
struct StatusLabel: View {
    let text: String
    let isError: Bool
    let size: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.quietHover) private var hover

    var body: some View {
        HStack(spacing: 4) {
            if isError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
            }
            Text(text)
                .font(.system(size: size).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(hover ? AnyShapeStyle(.primary)
            : isError || contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
}

/// M2.5 footer/band buttons: hover → `.primary` instantly, press → opacity 0.6 instantly. No scale, no animation.
/// Hover state lives in a tiny shared reference (`QuietHover`), set only on enter/leave, so no view state is added.
struct QuietButtonStyle: ButtonStyle {
    var id: String = ""

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, id: id, hover: QuietHover.shared)
    }

    private struct QuietBody: View {
        let configuration: ButtonStyle.Configuration
        let id: String
        let hover: QuietHover

        var body: some View {
            let hovering = !id.isEmpty && hover.id == id
            configuration.label
                .environment(\.quietHover, hovering)
                .opacity(configuration.isPressed || (DebugOverrides.press == "footer" && id.hasPrefix("footer.")) ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { inside in
                    guard !id.isEmpty else { return }
                    if inside { hover.id = id } else if hover.id == id { hover.id = nil }
                }
        }
    }
}

/// Which quiet button the pointer is over (at most one at a time).
@MainActor
@Observable
final class QuietHover {
    static let shared = QuietHover()
    var id: String?
}

private struct QuietHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `QuietButtonStyle` while the pointer is over the button; labels promote their text to `.primary`.
    var quietHover: Bool {
        get { self[QuietHoverKey.self] }
        set { self[QuietHoverKey.self] = newValue }
    }
}

/// M2.6 ⌘K chips: scale 0.97 with a 0.1 s ease-out bound to `isPressed` (in and out); Reduce Motion: opacity 0.8.
struct ChipPressStyle: ButtonStyle {
    /// DEBUG `BS_PRESS=chip:n` holds the pressed visual on chip n for state-matrix shots (always false in release).
    var heldForDebug = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || heldForDebug
        let rm = reduceMotion || DebugOverrides.reduceMotion
        return configuration.label
            .scaleEffect(pressed && !rm ? 0.97 : 1, anchor: .center)
            .opacity(pressed && rm ? 0.8 : 1)
            .animation(rm ? nil : .easeOut(duration: 0.1), value: pressed)
    }
}

/// The panel's target-screen backing scale (F11), set once per show by `PanelController`; proofs read it.
@MainActor
enum DisplayScale {
    static var current: CGFloat = 2
}
