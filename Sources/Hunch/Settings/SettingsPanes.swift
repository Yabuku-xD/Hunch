import AppKit
import HunchCore
import SwiftUI

// The four panes of v4 §5. System controls, unmodified (M2.7); every Form is `.grouped` and scrolls past the
// window's height cap.

/// M3.10: notes and errors fade in with 0.15 s ease-out bound to their value; Reduce Motion: instant.
private struct NoteFade<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: value)
    }
}

// MARK: General

struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Open \(AppInfo.name)") {
                    ShortcutRecorder(model: model.recorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Esc cancels recording. Delete resets to ⌥Space.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = model.recorder.error {
                        HotKeyErrorRow(message: error).transition(.opacity)
                    }
                }
                .modifier(NoteFade(value: model.recorder.error))
                LabeledContent {
                    Button("Open Keyboard Shortcuts…") { SystemLinks.open(SystemLinks.keyboardShortcuts) }
                } label: {
                    Text("To use ⌘Space, turn off Spotlight's shortcut first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Open at login")
                    if let note = model.loginNote { Text(note) }
                }
                if model.loginNote != nil {
                    Button("Open Login Items…") { model.openLoginItems() }
                }
            }
            Section("Help") {
                Button("Show Welcome Guide…") { model.onWelcome?() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Search

struct SearchPane: View {
    @Bindable var model: SettingsModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Form {
            Section {
                folderList
                HStack {
                    ControlGroup {
                        Button {
                            model.addFolders()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Folder")
                        Button {
                            model.removeSelected()
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(model.selectedRoot == nil)
                        .accessibilityLabel("Remove \(model.selectedRoot?.lastPathComponent ?? "folder")")
                    }
                    .fixedSize()
                    Spacer()
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Apps are always included.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Contents") {
                ForEach(ContentToggle.allCases, id: \.self) { t in
                    Toggle(isOn: Binding(get: { model.isOn(t) }, set: { model.set(t, $0) })) {
                        Text(t.title)
                        Text(model.caption(t)).monospacedDigit()
                    }
                    .disabled(t == .meaning && model.modelIsMissing)
                    .accessibilityValue(model.caption(t))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.startModelUpdates() }
        .onDisappear { model.stopModelUpdates() }
    }

    private var folderList: some View {
        List(selection: $model.selectedRoot) {
            ForEach(model.roots, id: \.self) { url in
                FolderRow(url: url, missing: model.missingRoots.contains(url)).tag(url)
            }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds(.disabled)
        .environment(\.defaultMinListRowHeight, 24)
        .frame(height: 144)
        .overlay {
            if model.roots.isEmpty {
                Text("No folders yet. Apps are still searchable.")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.add(urls) }
    }
}

private struct FolderRow: View {
    let url: URL
    let missing: Bool

    var body: some View {
        let tilde = (url.path as NSString).abbreviatingWithTildeInPath
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(FileManager.default.displayName(atPath: url.path)).lineLimit(1)
            Text(tilde)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if missing {
                Label("Not found", systemImage: "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(FileManager.default.displayName(atPath: url.path)), \(tilde)")
        .accessibilityValue(missing ? "Not found" : "")
    }
}

// MARK: Index

struct IndexPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Status") {
                Text(model.status.detail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Index status")
                    .accessibilityValue(model.status.detail)
                if let cloud = model.status.index?.cloudOnly, cloud > 0 {
                    Text("\(cloud.formatted()) files in iCloud aren't downloaded and are searched by name")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let unreadable = model.status.index?.unreadable, !unreadable.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Can't read these folders", systemImage: "exclamationmark.triangle")
                        ForEach(unreadable.prefix(20), id: \.self) { path in
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        HStack {
                            Button("Open Full Disk Access…") { SystemLinks.open(SystemLinks.fullDiskAccess) }
                                .buttonStyle(.borderedProminent)
                            Button("Open Files and Folders…") { SystemLinks.open(SystemLinks.filesAndFolders) }
                        }
                    }
                }
            }
            Section("Meaning model") {
                modelRows
                ModelLicenceLine()
            }
            Section("Maintenance") {
                HStack {
                    Button(model.isRebuilding ? "Checking…" : "Verify Index") { model.verify() }
                        .disabled(model.isRebuilding || model.admin == nil)
                    if let note = model.verifyNote {
                        Text(note).foregroundStyle(.secondary).transition(.opacity)
                    }
                    Spacer()
                    Button("Reset Index…", role: .destructive) { model.reset() }
                        .disabled(model.isRebuilding || model.admin == nil)
                }
                .modifier(NoteFade(value: model.verifyNote))
            }
        }
        .formStyle(.grouped)
        .onAppear { model.startModelUpdates() }
        .onDisappear { model.stopModelUpdates() }
    }

    @ViewBuilder private var modelRows: some View {
        switch model.modelState {
        case .ready(let m):
            LabeledContent("EmbeddingGemma 2 (Q8_0)") {
                Text("\(ModelCopy.size(m)) · \(ModelCopy.location(m.textSource))").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Show in Finder") { model.showModelInFinder() }
                if m.textSource == .downloaded {
                    Button("Remove…", role: .destructive) { model.confirmRemoveModel() }
                }
            }
        case .missing:
            LabeledContent("Not loaded") { Text("Names and contents only").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Choose Files…") { model.chooseModelFiles() }
                Button(ModelCopy.downloadButton) { model.models.download() }.buttonStyle(.borderedProminent)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p.fraction)
                Text(ModelCopy.progressCaption(p)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Button("Pause") { model.models.pause() }
                Button("Cancel") { model.models.cancel() }
            }
        case .paused(let p):
            Text(ModelCopy.pausedCaption(p)).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Resume") { model.models.download() }
                Button("Cancel") { model.models.cancel() }
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the download…").foregroundStyle(.secondary)
            }
        case .failed(let e, _):
            HotKeyErrorRow(message: ModelCopy.failure(e))
            HStack {
                Spacer()
                Button("Try Again") { model.models.download() }
            }
        }
    }
}

// MARK: About

/// Settings › About: the update check and, when a newer release exists, one button that installs it and relaunches.
struct UpdateRow: View {
    let updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            switch updater.phase {
            case .idle:
                Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            case .upToDate:
                Text("\(AppInfo.name) is up to date.").foregroundStyle(.secondary)
            case .available(let r):
                Text("\(AppInfo.name) \(r.version) is available.")
                Link("Release notes", destination: r.page)
            case .installing(let step):
                ProgressView().controlSize(.small)
                Text(step).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch updater.phase {
            case .available:
                Button("Update and Relaunch") { updater.install() }.keyboardShortcut(.defaultAction)
            case .checking, .installing:
                EmptyView()
            default:
                Button("Check for Updates") { updater.check() }
            }
        }
    }
}

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(AppInfo.name).font(.title2.weight(.semibold))
                    Text(versionLine)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Runs entirely on this Mac. No telemetry.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Button("Licenses") { openNotices() }
                Link("Source on GitHub", destination: AppInfo.repoURL)
            }
            Section {
                UpdateRow(updater: Updater.shared)
                Toggle("Check for updates automatically", isOn: Bindable(Updater.shared).automatic)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionLine: String {
        AppInfo.build.map { "Version \(AppInfo.version) (\($0))" } ?? "Version \(AppInfo.version)"
    }

    private func openNotices() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(AppInfo.repoURL.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
        }
    }
}
