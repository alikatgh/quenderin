#if canImport(SwiftUI)
import SwiftUI

/// Settings / manage: the active model, on-device storage, and the in-app About/Privacy (folded in
/// from `AboutView`). Reachable as a tab. Clearing conversations lives in the chat History sheet,
/// where the live `ConversationCoordinator` is — this screen reads the count for display.
/// Twin of Android `SettingsScreen`.
public struct SettingsView: View {
    @ObservedObject private var coordinator: ConversationCoordinator
    private let model: ModelEntry
    private let onSelectModel: (ModelEntry) -> Void
    @Environment(\.openURL) private var openURL
    @State private var showPicker = false
    @State private var installedModels: [InstalledModel] = []
    @State private var totalModelBytes: Int64 = 0

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
                Text("Browse, switch, or clear conversations from the History button in Chat.")
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
                        }
                        .accessibilityElement(children: .combine)
                        .deleteDisabled(installed.isActive)   // the loaded model can't be removed
                        // Swipe doesn't exist on macOS — the context menu is the Mac's delete
                        // affordance (and a harmless long-press extra on iOS).
                        .contextMenu {
                            if !installed.isActive {
                                Button("Delete", role: .destructive) { deleteModel(installed) }
                            }
                        }
                    }
                    .onDelete { offsets in offsets.forEach { deleteModel(installedModels[$0]) } }
                    LabeledRow(title: "Total on device", value: fileSize(totalModelBytes))
                }
                #if os(macOS)
                Text("Right-click a model to delete it and free space — the active model is protected.")
                    .font(.footnote).foregroundStyle(.secondary)
                #else
                Text("Swipe a model to delete it and free space — the active model is protected.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
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
                Text("Version \(version)")
                    .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

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
