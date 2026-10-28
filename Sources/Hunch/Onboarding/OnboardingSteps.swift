import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The guide's content: a scrolling step body over a fixed 52 pt footer (v4 §4 layout, 8 pt grid).
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Slide 16 pt + fade, spring 0.35 s bounce 0, interruptible; Reduce Motion: 150 ms crossfade.
    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let d = CGFloat(model.flow.direction) * 16
        return .asymmetric(
            insertion: .offset(x: d).combined(with: .opacity),
            removal: .offset(x: -d).combined(with: .opacity))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ZStack(alignment: .topLeading) {
                    StepView(model: model, step: model.step)
                        .id(model.step)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 32)
                .padding(.top, 24 + 28)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .animation(stepAnimation, value: model.step)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .debugAccessibilityOverrides()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            PageDots(current: model.step, count: OnboardingFlow.stepCount)
            Spacer()
            if model.flow.showsDontShowAgain {
                Button("Don't Show Again") { model.dontShowAgain() }
                    .buttonStyle(.link)
                    .padding(.trailing, 8)
            }
            if !model.flow.isFirst {
                Button("Back") { model.back() }
                    .buttonStyle(.bordered)
            }
            Button(model.primaryTitle) { model.primary() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.primaryDisabled)
        }
        .controlSize(.large)
        .padding(.horizontal, 32)
        .frame(height: 52)
    }
}

private struct PageDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...count, id: \.self) { i in
                Circle()
                    .fill(i == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(count)")
    }
}

/// One step: title, body, card. Entrance (first appearance only, M3.12): opacity 0→1 + scale 0.98→1, spring 0.35 s,
/// 40 ms stagger over three items. Reduce Motion: opacity only.
private struct StepView: View {
    let model: OnboardingModel
    let step: Int
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let appeared = model.appeared.contains(step)
        return VStack(alignment: .leading, spacing: 0) {
            if step == 1 {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .padding(.bottom, 16)
                    .accessibilityHidden(true)
                    .modifier(Entrance(appeared: appeared, index: 0))
            }
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .modifier(Entrance(appeared: appeared, index: 0))
            Group {
                if let body = bodyText {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .modifier(Entrance(appeared: appeared, index: 1))
            card
                .padding(.top, 24)
                .modifier(Entrance(appeared: appeared, index: 2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear {
            model.enter(step)
            titleFocused = true
            if let window = NSApp.keyWindow { NSAccessibility.post(element: window, notification: .layoutChanged) }
        }
    }

    private var title: String {
        switch step {
        case 1: "Find anything on your Mac"
        case 2: "Pick a shortcut"
        case 3: "Choose what to search"
        case 4: "Search by meaning"
        default: "You're set"
        }
    }

    private var bodyText: String? {
        let chord = model.recorder.shortcut.displayString
        switch step {
        case 1:
            return "Find apps, files and folders by name, and by what's inside them. Everything runs on this Mac "
                + "and stays on it."
        case 2:
            return "\(AppInfo.name) opens with ⌥Space. To use ⌘Space instead, turn off Spotlight's shortcut first, "
                + "then record ⌘Space here."
        case 3:
            return
                "Apps are always included. Add the folders you want searched. macOS asks once for each protected folder."
        case 4:
            return nil  // the card carries the state-specific copy
        default:
            return "Press \(chord) to try it. Indexing runs in the background, and search works by name right away."
        }
    }

    @ViewBuilder private var card: some View {
        switch step {
        case 1: GuideCard { WelcomeRows() }
        case 2: GuideCard { ShortcutCard(model: model) }
        case 3: GuideCard { FoldersCard(model: model) }
        case 4: GuideCard { ModelCard(model: model) }
        default: DoneCard(model: model)
        }
    }
}

/// Entrance for one item, bound to `appeared` (value-bound animation; interruptible).
private struct Entrance: ViewModifier {
    let appeared: Bool
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.98, anchor: .topLeading)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.15)
                    : .spring(duration: 0.35, bounce: 0).delay(Double(index) * 0.04), value: appeared)
    }
}

/// The step's control group: one glass card, radius 12. Reduce Transparency: opaque window background + 1 pt
/// separator stroke; Increase Contrast: the same stroke on glass.
private struct GuideCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let inner = VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if reduceTransparency {
                inner.background(Color(nsColor: .windowBackgroundColor), in: shape)
                    .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            } else if contrast == .increased {
                inner.glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            } else {
                inner.glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        }
    }
}

// MARK: Step 1

/// Three static Seam rows at the real 44 pt pitch (large theme tokens), not interactive.
private struct WelcomeRows: View {
    var body: some View {
        let t = Theme.large
        VStack(alignment: .leading, spacing: 0) {
            row(
                icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Preview.app"), title: "Preview",
                detail: Text("Application"), t: t)
            row(
                icon: NSWorkspace.shared.icon(for: .pdf), title: "Invoice March.pdf",
                detail: Text("…total due \(Text("€1,240").fontWeight(.semibold))…"), t: t)
            row(
                icon: NSWorkspace.shared.icon(for: .heic), title: "IMG_2231.heic",
                detail: Text("text in image: \(Text("Gate B12").fontWeight(.semibold))"), t: t)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example results: Preview, Invoice March.pdf, IMG_2231.heic")
    }

    private func row(icon: NSImage, title: String, detail: Text, t: Theme) -> some View {
        HStack(spacing: t.iconGap) {
            Image(nsImage: icon).resizable().frame(width: t.icon, height: t.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: t.titleSize, weight: .medium)).foregroundStyle(.primary)
                detail.font(.system(size: t.locationSize)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: t.nameContent + t.seam)
    }
}

// MARK: Step 2

private struct ShortcutCard: View {
    let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LabeledContent("Shortcut") { ShortcutRecorder(model: model.recorder) }
        Group {
            if let error = model.recorder.error {
                HotKeyErrorRow(message: error)
            } else if model.hotKeyWorks {
                Label {
                    Text("Works").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.system(size: 12))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            } else {
                Text("Press it now to try.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2),
            value: model.hotKeyWorks)
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Button("Open Keyboard Shortcuts…") { SystemLinks.open(SystemLinks.keyboardShortcuts) }
            Text("In Keyboard Shortcuts, choose Spotlight and turn off Show Spotlight search.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: Step 3

private struct FoldersCard: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.folders) { row in
                FolderCheckRow(model: model, row: row)
            }
        }
        Button("Add Folder…") { model.addFolder() }
        DisclosureGroup("Full Disk Access (optional)", isExpanded: $model.showsFDA) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Only needed for places macOS protects beyond these folders, like Mail or other apps' data. "
                        + "\(AppInfo.name) works without it."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") { SystemLinks.open(SystemLinks.fullDiskAccess) }
            }
            .padding(.top, 8)
        }
    }
}

private struct FolderCheckRow: View {
    let model: OnboardingModel
    let row: FolderChoice

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { row.checked || model.isDisabled(row) }, set: { _ in model.toggle(row.id) })) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(row.name)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(model.isDisabled(row))
            Spacer(minLength: 8)
            switch row.access {
            case .granted:
                Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityLabel("Access granted")
            case .denied:
                Text("No access").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Open Privacy Settings…") { SystemLinks.open(SystemLinks.filesAndFolders) }
                    .controlSize(.small)
            case .unknown:
                Text(row.countText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Step 4

private struct ModelCard: View {
    let model: OnboardingModel

    var body: some View {
        switch model.modelState {
        case .ready(let m) where !m.hasProjector:
            // Text model without the projector: meaning works for text; pictures fall back to the text in them.
            Text(
                "The EmbeddingGemma 2 text model is ready. Its image part isn't on this Mac, so pictures are "
                    + "matched by the text in them, not by what they show."
            )
            .copyStyle()
        case .ready:
            Text("The EmbeddingGemma 2 model is ready.").copyStyle()
        case .missing:
            Text(
                "Find files by meaning and pictures by what they show. The 865 MB model runs on this Mac; "
                    + "the download is \(AppInfo.name)'s only network use."
            )
            .copyStyle()
            Button("Text Only") { model.textOnly() }
        case .downloading(let p):
            ProgressView(value: p.fraction)
            Text(ModelCopy.progressCaption(p)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Button("Pause") { model.models.pause() }
        case .paused(let p):
            Text(ModelCopy.pausedCaption(p)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Button("Resume") { model.models.download() }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the download…").foregroundStyle(.secondary)
            }
        case .failed(let e, _):
            HotKeyErrorRow(message: ModelCopy.failure(e))
        }
        ModelLicenceLine()
    }
}

private extension Text {
    func copyStyle() -> some View {
        font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Step 5

/// The chosen chord as live 15 pt keycaps; a real press dips them to 0.94 and back.
private struct DoneCard: View {
    let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = model.keycapPressed
        return VStack(alignment: .leading, spacing: 12) {
            KeyCaps(caps: model.recorder.shortcut.keycaps, size: 15)
                .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                .opacity(pressed && reduceMotion ? 0.8 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
                .accessibilityLabel("Shortcut, \(model.recorder.shortcut.spokenName)")
            if case .downloading = model.modelState {
                Text("Meaning search turns on when the download finishes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if case .paused = model.modelState {
                Text("Meaning search turns on when the download finishes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
