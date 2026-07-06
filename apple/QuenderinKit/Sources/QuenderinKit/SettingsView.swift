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
        case appearance = "Appearance"
        case agent = "Agent"
        case storage = "Storage"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .model: return "cpu"
            case .appearance: return "paintbrush"
            case .agent: return "sparkles"
            case .storage: return "internaldrive"
            case .about: return "info.circle"
            }
        }
    }
    @State private var pane: Pane? = .model

    public var body: some View {
        content
            // Settings is its OWN window (scene) — RootView's preferredColorScheme doesn't
            // reach it, so picking "Light" used to change the app but not this window
            // (owner screenshot: Light selected, Settings still dark).
            .preferredColorScheme(appSettings.theme.colorScheme)
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
                    routingSection
                case .appearance:
                    appearancePreviewSection
                    appearanceSection
                case .agent:
                    capabilitiesSection
                    agentActivitySection
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
            routingSection
            appearancePreviewSection
            appearanceSection
            capabilitiesSection
            agentActivitySection
            storageSection
            downloadedModelsSection
            privacySection
            supportSection
            aboutSection
        }
        #endif
    }

    // MARK: Sections (shared by the Mac panes and the phone list)

    @ObservedObject private var appSettings = AppSettings.shared

    private var routingSection: some View {
        Section("Routing") {
            Toggle("Suggest the best model for each task", isOn: $appSettings.suggestBestModel)
            Text("When you start a chat, Quenderin checks what you're asking (code, reasoning, "
               + "another language) and offers the best installed model for it — a suggestion you "
               + "can tap, never a silent switch.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// A live two-bubble transcript that re-renders as the user moves any appearance control —
    /// see the result the moment you change it, not after hunting for a chat window (owner:
    /// "user will see instantly how everything will look"). Rendered in the EFFECTIVE scheme
    /// (the picked theme, or the system's when following it), so Theme flips inside the card
    /// even before the window catches up.
    private var appearancePreviewSection: some View {
        Section("Preview") {
            AppearancePreviewCard(settings: appSettings, systemScheme: scheme)
                .listRowInsets(EdgeInsets())
        }
    }

    // MARK: Agent capabilities + activity (AGENT_AUTONOMY_PLAN Milestone 0, step 5)

    /// Consent grants — the ONLY place they're set (never from code reachable by model output).
    private static let consentStore = UserDefaultsConsentStore()
    @State private var consentRefresh = false

    private struct CapabilityRow: Identifiable {
        let id: String
        let purpose: String
        let tier: CapabilityTier
        let requiresConsent: Bool
    }

    private var capabilityRows: [CapabilityRow] {
        AgentToolkit.capabilities().map {
            CapabilityRow(id: $0.name, purpose: $0.purpose, tier: $0.tier, requiresConsent: $0.requiresConsent)
        }
    }

    private func tierLabel(_ tier: CapabilityTier) -> String {
        switch tier {
        case .pureCompute: return "computes only — no side effects"
        case .readOnly: return "reads what you attach"
        case .reversibleWrite: return "makes undoable changes"
        case .appAction: return "acts in apps"
        case .irreversible: return "irreversible — never autonomous"
        }
    }

    private var capabilitiesSection: some View {
        Section("Agent capabilities") {
            ForEach(capabilityRows) { row in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.id).font(.body.weight(.medium))
                            Text(tierLabel(row.tier))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.requiresConsent {
                        Toggle("", isOn: Binding(
                            get: { Self.consentStore.isGranted(row.id) },
                            set: { Self.consentStore.setGranted(row.id, $0); consentRefresh.toggle() }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Allow \(row.id)")
                    } else {
                        Text("Always on").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("A capability above \u{201C}computes only\u{201D} runs ONLY with your permission — grant it here, "
               + "revoke it any time. The agent can never grant itself anything.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .id(consentRefresh)
    }

    private var agentActivitySection: some View {
        let entries = Array(FileAuditLedger().entries().suffix(10).reversed())
        return Section("Agent activity") {
            if entries.isEmpty {
                Text("Nothing yet. Every capability the agent uses — including the refused ones — "
                   + "is recorded here and in a plain file you can read.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entry.capability)(\(entry.input))")
                                .font(.callout.monospaced())
                                .lineLimit(1)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.decision)
                            .font(.caption.monospaced())
                            .foregroundStyle(entry.decision == "allowed" ? .secondary : Color.orange)
                    }
                }
                #if os(macOS)
                Button("Show the full ledger in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileAuditLedger.defaultURL()])
                }
                #endif
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appSettings.theme) {
                ForEach(AppSettings.Theme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Chat font", selection: $appSettings.chatFontStyle) {
                ForEach(AppSettings.ChatFontStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Text size", selection: $appSettings.chatFontSize) {
                ForEach(AppSettings.ChatFontSize.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Message bubbles", selection: $appSettings.bubbleAccent) {
                ForEach(AppSettings.BubbleAccent.allCases, id: \.self) { accent in
                    HStack {
                        Circle()
                            .fill(accent.colors(dark: scheme == .dark).bubble)
                            .frame(width: 12, height: 12)
                        Text(accent.label)
                    }
                    .tag(accent)
                }
            }
            Picker("Density", selection: $appSettings.messageDensity) {
                ForEach(AppSettings.MessageDensity.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Applies to the conversation text. Code blocks keep their own monospaced size. "
               + "Bubble colors are presets from the brand artwork — every choice stays Quenderin.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The preset a click is about to switch to, held for confirmation when it means a
    /// DOWNLOAD — a settings segment must never surprise-fetch gigabytes (owner feedback:
    /// "why does it open some other window" — the main window becoming the install screen
    /// out of nowhere).
    @State private var pendingPreset: ModelEntry?

    private var speedSection: some View {
        Section("Speed") {
                // The model-speed dial: decode speed scales with model SIZE, so this is the one
                // control that changes how fast replies FEEL.
                let choice = SpeedPresets.forDevice(totalRAMGB: HardwareProbe.current().totalRAMGB)
                let current = choice.preset(for: model.id)
                let installed = Set(FileManagerModelStorage(directory: OnboardingModel.defaultModelsDir()).installedFilenames())
                // Optional selection: a non-preset model must show NO selected segment (highlighting
                // "Quality" while the caption says otherwise contradicts itself).
                Picker("Speed", selection: Binding<SpeedPreset?>(
                    get: { current },
                    set: { picked in
                        guard let picked else { return }
                        let target = choice.model(picked)
                        guard target.id != model.id else { return }
                        if installed.contains(target.filename) {
                            onSelectModel(target)   // already on disk: switches in seconds
                        } else {
                            pendingPreset = target  // a download: ask before fetching gigabytes
                        }
                    }
                )) {
                    Text("Fast").tag(SpeedPreset.fast as SpeedPreset?)
                    Text("Balanced").tag(SpeedPreset.balanced as SpeedPreset?)
                    Text("Quality").tag(SpeedPreset.quality as SpeedPreset?)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Say what each preset IS and whether picking it downloads or just switches.
                Text("Fast: \(presetLine(choice.fast, installed: installed)) · Balanced: \(presetLine(choice.balanced, installed: installed)) · Quality: \(presetLine(choice.quality, installed: installed))")
                    .font(.footnote).foregroundStyle(.secondary)
                if current == nil {
                    Text("You're on \(model.label), which isn't one of these three — picking one switches to it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
        }
        .confirmationDialog(
            "Switch to \(pendingPreset?.label ?? "")?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
            titleVisibility: .visible,
            presenting: pendingPreset
        ) { target in
            Button("Download \(target.sizeLabel.replacingOccurrences(of: " download", with: "")) and switch") {
                onSelectModel(target)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("A one-time download — the main window shows progress and you can cancel any time. Your current model stays installed.")
        }
    }

    /// "Llama 3.2 3B (installed)" or "Llama 3 8B (4.7 GB)" — a glance says tap-or-download.
    private func presetLine(_ entry: ModelEntry, installed: Set<String>) -> String {
        installed.contains(entry.filename)
            ? "\(entry.label) — installed"
            : "\(entry.label) — \(entry.sizeLabel.replacingOccurrences(of: " download", with: ""))"
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
                // Q-578: the DownloadPolicy reason string tells users to "allow cellular downloads in
                // settings" — this is that opt-in (off by default; onboarding + library gates read it).
                Toggle("Allow downloads over cellular", isOn: $appSettings.allowCellularDownloads)
                Text("Off by default — models are multiple GB, so downloads wait for Wi-Fi. Turn this on to allow cellular data.")
                    .font(.footnote).foregroundStyle(.secondary)
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

/// The Appearance pane's live preview: a two-bubble transcript drawn with the SAME tokens the
/// real chat uses (palette, bubble accent, chat font, density), in the EFFECTIVE color scheme —
/// the picked theme, or the system's while following it. Every control change re-renders it.
private struct AppearancePreviewCard: View {
    @ObservedObject var settings: AppSettings
    let systemScheme: ColorScheme

    var body: some View {
        let effective: ColorScheme = settings.theme.colorScheme ?? systemScheme
        let dark = effective == .dark
        let p = QuenderinPalette.of(effective)
        let accent = settings.bubbleAccent.colors(dark: dark)

        VStack(alignment: .leading, spacing: settings.messageDensity.spacing) {
            HStack(alignment: .bottom) {
                previewBubble(
                    text: "Every word of this reply is computed on your \(deviceNoun).",
                    background: p.assistantBubble, textColor: p.onAssistantBubble,
                    timestampColor: p.assistantTimestamp
                )
                Spacer(minLength: 48)
            }
            HStack(alignment: .bottom) {
                Spacer(minLength: 48)
                previewBubble(
                    text: "And it will look exactly like this?",
                    background: accent.bubble, textColor: accent.text,
                    timestampColor: accent.timestamp
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(p.background)
        // The card carries its own scheme so Theme flips INSIDE it instantly, independent of
        // how fast the window around it follows.
        .environment(\.colorScheme, effective)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the chat appearance with the current settings")
    }

    private func previewBubble(text: String, background: Color, textColor: Color, timestampColor: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(text)
                .font(settings.chatFont)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("09:41")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(timestampColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
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
