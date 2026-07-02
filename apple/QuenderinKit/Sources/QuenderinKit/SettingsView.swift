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

    public var body: some View {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        return List {
            Section("Speed") {
                // The model-speed dial: decode speed scales with model SIZE, so this is the one
                // control that changes how fast replies FEEL. Selecting a preset runs the normal
                // switch flow (download if needed → load → swap).
                let choice = SpeedPresets.forDevice(totalRAMGB: HardwareProbe.current().totalRAMGB)
                let current = choice.preset(for: model.id)
                Picker("Speed", selection: Binding(
                    get: { current ?? .quality },
                    set: { picked in
                        let target = choice.model(picked)
                        if target.id != model.id { onSelectModel(target) }
                    }
                )) {
                    Text("Fast").tag(SpeedPreset.fast)
                    Text("Balanced").tag(SpeedPreset.balanced)
                    Text("Quality").tag(SpeedPreset.quality)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(current == nil
                     ? "Custom model active (\(model.label)) — pick a preset to switch."
                     : "Fast: \(choice.fast.label) · Balanced: \(choice.balanced.label) · Quality: \(choice.quality.label). Switching downloads the model if needed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Model") {
                LabeledRow(title: "Active model", value: model.label)
                LabeledRow(title: "Size", value: model.sizeLabel)
                Button { showPicker = true } label: {
                    Label("Change model…", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("Runs entirely on-device via llama.cpp — no cloud.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledRow(title: "Saved conversations", value: "\(coordinator.summaries.count)")
                Text("Browse, switch, or clear conversations from the History button in Chat.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
                    }
                    .onDelete { offsets in offsets.forEach { deleteModel(installedModels[$0]) } }
                    LabeledRow(title: "Total on device", value: fileSize(totalModelBytes))
                }
                Text("Swipe a model to delete it and free space — the active model is protected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                if let url = URL(string: SupportContact.privacyPolicyURL) {
                    Button { openURL(url) } label: { Label("Privacy Policy", systemImage: "lock.shield") }
                }
                Text(SupportContact.aiDisclaimer)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Support") {
                if let url = URL(string: "mailto:\(SupportContact.reportEmail)") {
                    Button { openURL(url) } label: { Label("Contact support", systemImage: "envelope") }
                }
            }
            Section {
                Text("Quenderin runs entirely on your device. No account, no cloud, no tracking — "
                   + "once a model is downloaded it works fully offline, and nothing you type leaves your phone.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { reloadModelStorage() }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                // Reuses the fitness-aware picker (disables models that won't fit, explains why).
                ModelPickerView(totalRAMGB: HardwareProbe.current().totalRAMGB) { picked in
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
