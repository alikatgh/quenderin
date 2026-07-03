#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings / manage: the active model, on-device storage, and the in-app About/Privacy (folded in
/// from `AboutView`). Reachable as a tab. Clearing conversations lives in the chat History sheet,
/// where the live `ConversationCoordinator` is — this screen reads the count for display.
/// Twin of Android `SettingsScreen`.
public struct SettingsView: View {
    @ObservedObject private var coordinator: ConversationCoordinator
    private let model: ModelEntry
    private let onSelectModel: (ModelEntry) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @State private var showPicker = false
    @State private var installedModels: [InstalledModel] = []
    @State private var totalModelBytes: Int64 = 0
    @State private var pendingModelDelete: InstalledModel?
    @State private var confirmClearConversations = false

    public init(coordinator: ConversationCoordinator, model: ModelEntry, onSelectModel: @escaping (ModelEntry) -> Void) {
        self.coordinator = coordinator
        self.model = model
        self.onSelectModel = onSelectModel
    }

    /// A fresh manager over the on-disk models dir each access — the files on disk are the source of
    /// truth, so a new instance always reflects the current state (the active model is pinned + protected).
    private var modelManager: ModelManager {
        ModelManager(
            storage: FileManagerModelStorage(directory: OnboardingModel.defaultModelsDir()),
            activeModelID: model.id)
    }

    private func reloadModelStorage() {
        let mgr = modelManager
        installedModels = mgr.installed()
        totalModelBytes = mgr.totalBytesUsed
    }

    private func deleteModel(_ installed: InstalledModel) {
        guard !installed.isActive else { return }   // never delete the loaded model
        _ = modelManager.delete(installed.model.id)
        reloadModelStorage()
    }

    private func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// What the Settings window can show, as System-Settings-style sidebar panes (macOS).
    private enum Pane: String, CaseIterable, Identifiable {
        case model = "Model"
        case storage = "Storage"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .model: return "cpu"
            case .storage: return "internaldrive"
            case .about: return "info.circle"
            }
        }
    }
    @State private var pane: Pane? = .model

    public var body: some View {
        content
            .onAppear { reloadModelStorage() }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    // Reuses the fitness-aware picker (disables models that won't fit, explains why).
                    ModelPickerView(totalRAMGB: HardwareProbe.current().totalRAMGB, currentModelID: model.id) { picked in
                        showPicker = false
                        if picked.id != model.id { onSelectModel(picked) }
                    }
                    .navigationTitle("Choose a model")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showPicker = false } }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // The Mac idiom: a System-Settings-style sidebar of panes, not one long phone list.
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
            // System Settings has no collapse chevron — a settings sidebar that can vanish is a trap.
            .removeSidebarToggle()
        } detail: {
            Form {
                switch pane ?? .model {
                case .model:
                    speedSection
                    modelSection
                case .storage:
                    storageSection
                    downloadedModelsSection
                case .about:
                    privacySection
                    supportSection
                    aboutSection
                }
            }
            .formStyle(.grouped)
        }
        // Brand accent on selection/controls (the default system blue reads as someone else's app),
        // and a floor under the window so it can never shrink into a sidebar-only sliver.
        .tint(QuenderinPalette.of(scheme).primary)
        .frame(minWidth: 640, minHeight: 420)
        #else
        List {
            speedSection
            modelSection
            storageSection
            downloadedModelsSection
            privacySection
            supportSection
            aboutSection
        }
        #endif
    }

    // MARK: Sections (shared by the Mac panes and the phone list)

    private var speedSection: some View {
        Section("Speed") {
                // The model-speed dial: decode speed scales with model SIZE, so this is the one
                // control that changes how fast replies FEEL. Selecting a preset runs the normal
                // switch flow (download if needed → load → swap).
                let choice = SpeedPresets.forDevice(totalRAMGB: HardwareProbe.current().totalRAMGB)
                let current = choice.preset(for: model.id)
                // Optional selection: a CUSTOM model must show NO selected segment (highlighting
                // "Quality" while the caption says "custom model active" contradicts itself —
                // Android's chips already behave this way).
                Picker("Speed", selection: Binding<SpeedPreset?>(
                    get: { current },
                    set: { picked in
                        guard let picked else { return }
                        let target = choice.model(picked)
                        if target.id != model.id { onSelectModel(target) }
                    }
                )) {
                    Text("Fast").tag(SpeedPreset.fast as SpeedPreset?)
                    Text("Balanced").tag(SpeedPreset.balanced as SpeedPreset?)
                    Text("Quality").tag(SpeedPreset.quality as SpeedPreset?)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(current == nil
                     ? "Custom model active (\(model.label)) — pick a preset to switch."
                     : "Fast: \(choice.fast.label) · Balanced: \(choice.balanced.label) · Quality: \(choice.quality.label). Switching downloads the model if needed.")
                    .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section("Model") {
                LabeledRow(title: "Active model", value: model.label)
                LabeledRow(title: "Size", value: model.sizeLabel)
                Button { showPicker = true } label: {
                    Label("Change model…", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("Runs entirely on-device via llama.cpp — no cloud.")
                    .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
                LabeledRow(title: "Saved conversations", value: "\(coordinator.summaries.count)")
                Button(role: .destructive) { confirmClearConversations = true } label: {
                    Label("Clear all conversations…", systemImage: "trash")
                }
                .disabled(coordinator.summaries.isEmpty)
                .confirmationDialog(
                    "Delete all \(coordinator.summaries.count) conversations?",
                    isPresented: $confirmClearConversations, titleVisibility: .visible
                ) {
                    Button("Delete all", role: .destructive) { coordinator.clearAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes every saved conversation from this \(deviceNoun). It can't be undone.")
                }
                Text("Browse or switch conversations from the sidebar in Chat.")
                    .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var downloadedModelsSection: some View {
        Section("Downloaded models") {
                if installedModels.isEmpty {
                    Text("No models downloaded yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(installedModels) { installed in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(installed.model.label)
                                if installed.isActive {
                                    Text("Active").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(fileSize(installed.sizeBytes)).foregroundStyle(.secondary)
                            // A VISIBLE per-row action menu — right-click alone is a hidden door.
                            Menu {
                                modelActions(installed)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Actions for \(installed.model.label)")
                        }
                        .accessibilityElement(children: .combine)
                        .deleteDisabled(installed.isActive)   // the loaded model can't be removed
                        // Right-click (macOS) / long-press (iOS) offers the same actions as the ⋯ menu.
                        .contextMenu {
                            modelActions(installed)
                        }
                    }
                    .onDelete { offsets in offsets.forEach { deleteModel(installedModels[$0]) } }
                    LabeledRow(title: "Total on device", value: fileSize(totalModelBytes))
                }
                Text("The ⋯ menu on each model can delete it and free space — the active model is protected.")
                    .font(.footnote).foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Delete \(pendingModelDelete?.model.label ?? "this model")?",
            isPresented: Binding(
                get: { pendingModelDelete != nil },
                set: { if !$0 { pendingModelDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingModelDelete
        ) { installed in
            Button("Delete (frees \(fileSize(installed.sizeBytes)))", role: .destructive) {
                deleteModel(installed)
            }
            Button("Cancel", role: .cancel) {}
        } message: { installed in
            Text("You can download \(installed.model.label) again later — it just won't be on this \(deviceNoun).")
        }
    }

    /// The shared per-model actions (the ⋯ menu and the context menu must never drift apart).
    @ViewBuilder
    private func modelActions(_ installed: InstalledModel) -> some View {
        #if os(macOS)
        Button("Show in Finder") {
            let url = OnboardingModel.defaultModelsDir().appendingPathComponent(installed.model.filename)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
        if installed.isActive {
            Button("Active — in use") {}.disabled(true)
        } else {
            Button("Delete…", role: .destructive) { pendingModelDelete = installed }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
                if let url = URL(string: SupportContact.privacyPolicyURL) {
                    Button { openURL(url) } label: { Label("Privacy Policy", systemImage: "lock.shield") }
                }
                Text(SupportContact.aiDisclaimer)
                    .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var supportSection: some View {
        Section("Support") {
                if let url = URL(string: "mailto:\(SupportContact.reportEmail)") {
                    Button { openURL(url) } label: { Label("Contact support", systemImage: "envelope") }
                }
        }
    }

    private var aboutSection: some View {
        Section {
                Text("Quenderin runs entirely on your device. No account, no cloud, no tracking — "
                   + "once a model is downloaded it works fully offline, and nothing you type leaves your \(deviceNoun).")
                    .font(.footnote).foregroundStyle(.secondary)
                // Open source is a feature — say so where users look for "who made this".
                if let url = URL(string: SupportContact.githubURL) {
                    Button { openURL(url) } label: {
                        Label("Quenderin is open source — view on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Text("Version \(version)")
                    .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
private extension View {
    /// Hide the sidebar-collapse chevron (macOS 14+); a no-op on 13 where the API doesn't exist.
    @ViewBuilder func removeSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}
#endif

/// A title-on-the-left, value-on-the-right settings row.
private struct LabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
