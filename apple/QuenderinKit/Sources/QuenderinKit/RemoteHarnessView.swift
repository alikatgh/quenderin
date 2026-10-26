#if canImport(SwiftUI)
import SwiftUI

/// Native computer destination; local conversations and provider keys are never
/// dependencies of this view or its controller.
public struct RemoteHarnessView: View {
    @ObservedObject private var controller: RemoteHarnessClientController
    @StateObject private var presentation = RemoteHarnessPresentationPreferences()
    private let showsDoneButton: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var origin = ""
    @State private var email = ""
    @State private var password = ""
    @State private var deviceName = "Quenderin"
    @State private var selectedModel = ""
    @State private var effort = ""
    @FocusState private var composerFocused: Bool
    public init(controller: RemoteHarnessClientController = .shared, showsDoneButton: Bool = false) {
        self.controller = controller; self.showsDoneButton = showsDoneButton
    }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let failure = controller.failure, controller.screen != .session {
                    Text(failure.localizedDescription).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().accessibilityIdentifier("remote-error")
                }
                if controller.busy { ProgressView("Connecting to your computer…").padding().accessibilityIdentifier("remote-progress") }
                if !controller.companionAvailable, !controller.busy, [.workspaces, .sessions].contains(controller.screen) {
                    Text(RemoteHarnessClientFailure.companionRequired.localizedDescription).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("remote-companion-required")
                }
                content
            }
            .navigationTitle("My computer")
            .toolbar {
                if showsDoneButton { ToolbarItem(placement: .confirmationAction) { Button("Done") { password = ""; dismiss() } } }
                if controller.journal.origin != nil, controller.screen != .setup {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if let text = controller.unsavedDraftForCopy {
                                Button { copyToPasteboard(text) } label: { Label("Copy unsaved draft", systemImage: "doc.on.doc") }
                                    .accessibilityIdentifier("remote-copy-unsaved-draft")
                            }
                            if let sessionID = controller.journal.sessionID {
                                Button { copyToPasteboard(sessionID) } label: { Label("Copy session ID", systemImage: "doc.on.doc") }
                                    .accessibilityIdentifier("remote-copy-session-id")
                            }
                            Section("On this device") {
                                Toggle("Wrap code", isOn: $presentation.wrapsCode)
                                Picker("Conversation text size", selection: $presentation.textSize) {
                                    ForEach(RemoteHarnessPresentationPreferences.TextSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                                }
                            }
                            Button("Reconnect") { Task { await controller.reconnect() } }.disabled(controller.busy)
                            Button("Computer list") { controller.showComputers() }.disabled(controller.busy)
                            Button("Sign in again") { controller.showSetup() }
                            Button("Disconnect") { controller.disconnect() }
                        } label: { Label("Connection", systemImage: "network") }
                        .accessibilityIdentifier("remote-connection-menu")
                    }
                }
            }
        }
        .onAppear { origin = controller.journal.origin ?? ""; selectedModel = controller.selectedModelID; effort = controller.selectedEffort }
        .task { if scenePhase == .active { await controller.reconcileForeground() } }
        .onDisappear { password = "" }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await controller.reconcileForeground() } }
        }
        .onChange(of: controller.selectedModelID) { selectedModel = $0 }
        .onChange(of: controller.selectedEffort) { effort = $0 }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 480)
        #endif
    }
    @ViewBuilder private var content: some View {
        switch controller.screen {
        case .setup: setup
        case .computers: computerList
        case .trust: trust
        case .workspaces: workspaceList
        case .sessions: sessionList
        case .session: session
        case .disconnected: recovery
        }
    }
    private var setup: some View {
        Form {
            Section {
                Text("Run DeepSeek Harness on your computer and control it here. Tasks and tools execute on that computer. Your local chats stay on this device.")
            }
            if controller.cryptoAvailable {
                Section("Your Remote Harness server") {
                    TextField("HTTPS server origin", text: $origin).accessibilityIdentifier("remote-server")
                        .autocorrectionDisabled()
                    Text("Use the HTTPS origin of your self-hosted server. This connection does not create an account or start a hosted service.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Server account") {
                    TextField("Account email", text: $email).autocorrectionDisabled().accessibilityIdentifier("remote-email")
                    SecureField("Password", text: $password)
                        .textContentType(nil).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("remote-password")
                    TextField("This device’s name", text: $deviceName).accessibilityIdentifier("remote-device-name")
                    Button("Authorize this device") {
                        let entry = password; password = ""
                        Task { await controller.authorize(origin: origin, email: email, password: entry, deviceName: deviceName) }
                    }
                    .disabled(controller.busy || password.isEmpty || email.isEmpty || origin.isEmpty)
                    .accessibilityIdentifier("remote-authorize")
                }
                Text("Your password is used only for this sign-in. The device identity and rotating tokens are stored separately in this device’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Section("Secure connection runtime required") {
                    Text(RemoteHarnessClientFailure.cryptoUnavailable.localizedDescription).accessibilityIdentifier("remote-crypto-unavailable")
                }
            }
        }
        .formStyle(.grouped)
    }
    private var computerList: some View {
        List {
            Section { destination }
            Section("Authorized computers") {
                if controller.hosts.isEmpty { Text("No computers are registered on this account. Register the Harness Host on your computer, then reconnect.").foregroundStyle(.secondary) }
                ForEach(controller.hosts) { host in
                    Button { Task { await controller.selectHost(host) } } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) { Text(host.name); Text(host.platform).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(host.online ? "Online" : "Offline").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(controller.busy || !host.online).accessibilityIdentifier("remote-host-\(host.deviceID)")
                }
            }
        }
    }
    private var trust: some View {
        Form {
            Section("Verify your computer") {
                Text(controller.pendingHost?.name ?? "Computer").font(.headline)
                Text("Compare this entire SHA-256 identity fingerprint with the fingerprint shown by the Harness Host. Confirm only when every character matches.")
                Text(controller.pendingFingerprint ?? "Fingerprint unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("remote-full-fingerprint")
                Text("The computer must also confirm this device before the connection is accepted. A changed identity is never trusted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Fingerprint matches — trust computer") { Task { await controller.trustHost() } }
                    .disabled(controller.busy || controller.pendingFingerprint == nil).accessibilityIdentifier("remote-trust")
                Button("Back to computers") { controller.showComputers() }.disabled(controller.busy)
            }
            Section("Confirm this device on the computer") {
                Text("Use the Host companion pairing command on your computer with these public device values. Compare the entire fingerprint before confirming.")
                if let id = controller.clientDeviceID { LabeledContent("Device ID") { Text(id).textSelection(.enabled) } }
                if let identity = controller.clientPublicIdentity { Text("Public identity").font(.caption); Text(identity).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                if let fingerprint = controller.clientFingerprint { Text("SHA-256 fingerprint").font(.caption); Text(fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }.accessibilityIdentifier("remote-client-public-pairing")
        }.formStyle(.grouped)
    }
    private var workspaceList: some View {
        List {
            Section { destination }
            Section("Workspaces on \(controller.computerName)") {
                if controller.workspaces.isEmpty { Text("The Host has no workspaces. Open a workspace in DeepSeek Harness on the computer, then reconnect.").foregroundStyle(.secondary) }
                ForEach(controller.workspaces) { workspace in
                    Button { Task { await controller.selectWorkspace(workspace) } } label: {
                        VStack(alignment: .leading) { Text(workspace.title); Text(workspace.path).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(controller.busy).accessibilityIdentifier("remote-workspace-\(workspace.workspaceID)")
                }
            }
        }
    }
    private var sessionList: some View {
        List {
            Section { destination }
            Section(controller.workspaceTitle) {
                Button { Task { await controller.createSession() } } label: { Label("New session on computer", systemImage: "square.and.pencil") }
                    .disabled(!controller.canCreateSession).accessibilityIdentifier("remote-new-session")
                if controller.sessions.isEmpty { Text("No sessions in this workspace yet.").foregroundStyle(.secondary) }
                ForEach(controller.sessions) { session in
                    Button { Task { await controller.selectSession(session) } } label: {
                        HStack { Text(session.title); Spacer(); if session.running { Text("Running").font(.caption).foregroundStyle(.secondary) } }
                    }.disabled(controller.busy).accessibilityIdentifier("remote-session-\(session.sessionID)")
                }
            }
            bots
        }
    }
    private struct BotListItem: Identifiable {
        let bot: RemoteHarnessBot
        var id: Data { Data(bot.id.utf8) }
    }
    private var bots: some View {
        Section("Bots") {
            if !controller.botReadAvailable {
                Text(controller.companionAvailable ? "Bots aren’t available from this computer." : "Connect to your computer to view its bots.")
                    .foregroundStyle(.secondary).accessibilityIdentifier("remote-bots-unsupported")
            } else {
                refreshBotsButton
                if controller.botLoading {
                    ProgressView(controller.botRoster == nil ? "Loading bots…" : "Refreshing bots…")
                        .accessibilityIdentifier("remote-bots-loading")
                }
                if controller.botUnavailable {
                    Text("Bots couldn’t be loaded. Refresh bots to try again when your computer is ready.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("remote-bots-unavailable")
                } else if let roster = controller.botRoster {
                    if roster.bots.isEmpty {
                        Text("No bots in this workspace.").foregroundStyle(.secondary).accessibilityIdentifier("remote-bots-empty")
                    }
                    ForEach(roster.bots.map { BotListItem(bot: $0) }) { item in
                        let bot = item.bot
                        Button { Task { await controller.openBotSession(bot) } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bot.name)
                                Text("Model: \(bot.model ?? "Not provided")").font(.caption).foregroundStyle(.secondary)
                                Text("Permission: \(bot.permission ?? "Not provided")").font(.caption).foregroundStyle(.secondary)
                                if !controller.canOpenBot(bot) {
                                    Text("Current session unavailable").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(controller.busy || controller.botLoading || !controller.canOpenBot(bot))
                        .accessibilityHint("Opens this bot’s current conversation for viewing.")
                        .accessibilityIdentifier("remote-bot-\(item.id.base64EncodedString())")
                    }
                    Text("Open a bot to read its current conversation. Send messages and change bot settings on your computer.")
                        .font(.caption).foregroundStyle(.secondary)
                    if roster.readOnly {
                        Text("Bot changes are currently disabled on the computer.")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("remote-bots-host-read-only")
                    }
                } else if !controller.botLoading {
                    Text("Refresh bots to see this workspace’s bots.").foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("remote-bots")
    }
    private var refreshBotsButton: some View {
        Button { Task { await controller.refreshBots() } } label: { Label("Refresh bots", systemImage: "arrow.clockwise") }
            .disabled(!controller.botReadAvailable || controller.botLoading).accessibilityIdentifier("remote-refresh-bots")
    }
    private var recovery: some View {
        VStack(alignment: .leading, spacing: 16) {
            destination
            Text("Computer disconnected").font(.title2)
            Text("Reconnect to recover the exact saved session and its authoritative history. Commands with an uncertain outcome are retained and are never sent again automatically.")
                .foregroundStyle(.secondary)
            if let sessionID = controller.journal.sessionID { Text("Saved session: \(sessionID)").font(.caption).textSelection(.enabled) }
            Button("Reconnect and recover session") { Task { await controller.reconnect() } }
                .buttonStyle(.borderedProminent).disabled(controller.busy).accessibilityIdentifier("remote-recover")
            Button("Sign in again") { controller.showSetup() }.disabled(controller.busy)
            if !controller.timeline.rows.isEmpty {
                Text("Saved history · awaiting Host refresh").font(.caption).foregroundStyle(.secondary)
                history
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var session: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    sessionHeader
                    historyRows
                }.padding().frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("remote-timeline")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !controller.approvals.isEmpty {
                        ScrollView { approvalControls }
                            .frame(maxHeight: min(260, max(100, geometry.size.height * 0.35)))
                            .accessibilityLabel("Pending computer approvals")
                    }
                    Divider()
                    composer
                }
                .background(.regularMaterial)
            }
        }
    }
    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = controller.failure {
                Text(failure.localizedDescription).font(.callout).foregroundStyle(.red).accessibilityIdentifier("remote-error")
            }
            if !controller.companionAvailable, !controller.busy {
                Text(RemoteHarnessClientFailure.companionRequired.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("remote-companion-required")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(controller.sessionTitle).font(.headline)
                Spacer()
                Button { Task { await controller.refreshSessionState() } } label: { Label("Refresh status", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly).disabled(controller.busy).accessibilityIdentifier("remote-refresh-status")
            }
            if controller.running { Text("Running on computer").font(.caption.weight(.semibold)) }
            Text(stopLabel).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Computer and session details") {
                VStack(alignment: .leading, spacing: 8) {
                    destination
                    if let sessionID = controller.journal.sessionID {
                        Text("Session: \(sessionID)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    if controller.isBotSessionReadOnly || controller.botReadAvailable || controller.botSessionClassificationPending { sessionBotStatus }
                    if !controller.isBotSessionReadOnly { modelControls }
                }
            }
        }
    }
    private var composer: some View {
        let destination = controller.composerDestination
        return VStack(alignment: .leading, spacing: 8) {
            if controller.unsavedDraftForCopy != nil {
                Text("This draft hasn’t been saved. Copy it from the Connection menu before leaving.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("remote-unsaved-draft")
            }
            if !controller.isBotSessionReadOnly {
                TextField("Task for this computer", text: Binding(
                    get: { controller.draft(for: destination) }, set: { controller.updateDraft($0, for: destination) }
                ), axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).disabled(controller.botSessionClassificationPending)
                    .focused($composerFocused).accessibilityIdentifier("remote-composer")
            }
            HStack {
                #if os(iOS)
                if composerFocused {
                    Button { composerFocused = false } label: { Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down") }
                        .labelStyle(.iconOnly).accessibilityIdentifier("remote-hide-keyboard")
                }
                #endif
                Spacer()
                Button("Stop") { Task { await controller.stop() } }.disabled(!controller.canStop)
                    .accessibilityValue(stopLabel).accessibilityIdentifier("remote-stop")
                if !controller.isBotSessionReadOnly {
                    Button("Send") {
                        guard let submission = controller.submission(for: destination) else { return }
                        Task { await controller.send(submission) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!controller.canSend).accessibilityIdentifier("remote-send")
                }
            }
        }.padding(.horizontal).padding(.vertical, 8)
    }
    private var sessionBotStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isBotSessionReadOnly {
                Label("Bot session · View only", systemImage: "eye").font(.callout.weight(.semibold))
                    .accessibilityIdentifier("remote-bot-session-read-only")
                Text("Read the conversation here. Send messages and change bot settings on your computer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller.botSessionClassificationPending && !controller.isBotSessionReadOnly {
                if controller.botLoading {
                    ProgressView("Checking session access…")
                } else {
                    Text(controller.botUnavailable
                         ? "Session access couldn’t be checked. Refresh bots to try again. Your draft is kept."
                         : "Refresh bots to check session access before sending a task or changing the model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if controller.botLoading {
                ProgressView("Refreshing bots…")
            } else if controller.botUnavailable {
                Text("Bots couldn’t be refreshed. Try again when your computer is ready.").font(.caption).foregroundStyle(.secondary)
            }
            if controller.botReadAvailable {
                refreshBotsButton
            } else if controller.isBotSessionReadOnly {
                Text("The bot list isn’t available from this computer. This conversation remains view only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("remote-session-bot-status")
    }
    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                historyRows
            }.padding().frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("remote-timeline")
    }
    private var historyRows: some View {
        Group {
            if controller.timeline.hasMore { Button("Load earlier messages") { Task { await controller.loadEarlier() } }.disabled(controller.busy) }
            ForEach(controller.timeline.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if row.kind == "reasoning" {
                        DisclosureGroup("Reasoning") { boundedRawText(row.text) }
                    } else if row.kind == "tool" {
                        Text(RemoteHarnessRawTextPage(row.text, index: 0).text).lineLimit(3).textSelection(.enabled)
                        DisclosureGroup("Full tool output") { boundedRawText(row.text) }
                        DisclosureGroup("Tool details") { boundedRawText(String(decoding: row.raw, as: UTF8.self)) }
                    } else if row.kind == "assistant" {
                        RemoteHarnessAssistantText(text: row.text, wrapsCode: presentation.wrapsCode, codeTextStyle: codeTextStyle)
                    } else if row.text.utf8.count > RemoteHarnessTextBudget.maximumRawPageBytes {
                        boundedRawText(row.text)
                    } else {
                        Text(row.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(conversationFont).accessibilityIdentifier("remote-timeline-row")
            }
        }
    }
    private var conversationFont: Font {
        switch presentation.textSize {
        case .standard: return .body
        case .larger: return .title3
        case .largest: return .title2
        }
    }
    private var codeTextStyle: Font.TextStyle {
        switch presentation.textSize {
        case .standard: return .footnote
        case .larger: return .callout
        case .largest: return .body
        }
    }
    private func boundedRawText(_ text: String) -> some View {
        RemoteHarnessRawText(text: text, textStyle: codeTextStyle)
    }
    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model on computer", selection: $selectedModel) {
                ForEach(controller.models) { model in Text(model.name).tag(model.id) }
            }.accessibilityIdentifier("remote-model")
            if let model = controller.models.first(where: { $0.id == selectedModel }), !model.efforts.isEmpty {
                Picker("Effort", selection: $effort) { Text("Default").tag(""); ForEach(model.efforts, id: \.self) { Text($0).tag($0) } }.accessibilityIdentifier("remote-effort")
            }
            Button("Apply") { Task { await controller.selectModel(selectedModel, effort: effort) } }.disabled(!controller.canChangeModel || selectedModel.isEmpty)
        }.disabled(!controller.canChangeModel)
    }
    private var approvalControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.approvalCards) { card in
                let approval = card.approval
                Text(card.action?.toolName ?? card.toolName).font(.headline)
                if let callID = card.action?.callID ?? card.callID {
                    Text("Call ID: \(callID)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let reason = card.reason { Text(reason).font(.callout) }
                if let action = card.action {
                    Text("Exact tool arguments").font(.caption.weight(.semibold))
                    ScrollView([.horizontal, .vertical]) {
                        Text(action.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true).privacySensitive()
                    }.frame(maxHeight: 180).accessibilityIdentifier("remote-approval-exact-arguments")
                } else {
                    Text("Full action details aren’t available yet. Review the action on your computer, or use Stop.")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("remote-approval-action-unavailable")
                }
                DisclosureGroup("Approval request metadata") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(card.metadata).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true).privacySensitive()
                    }.frame(maxHeight: 140)
                }.accessibilityIdentifier("remote-approval-metadata")
                if let binding = approval.extensionBinding {
                    Text("Run \(binding.runID) · Host expiry \(Date(timeIntervalSince1970: Double(binding.expiresAt) / 1000).formatted())").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Deny") { Task { await controller.decide(approval, allow: false) } }
                        Button("Allow once") { Task { await controller.decide(approval, allow: true) } }
                    }.disabled(controller.busy || card.action == nil)
                } else { Text("This Host does not provide the required bound approval extension. Review and answer on the computer.").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding().accessibilityIdentifier("remote-approval")
    }
    private var destination: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(controller.journal.origin ?? "Your self-hosted server").font(.caption).foregroundStyle(.secondary)
            Label("\(controller.computerName) · \(controller.workspaceTitle)", systemImage: "desktopcomputer").font(.callout)
            Text("Execution: remote computer").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("remote-execution-location")
    }
    private var stopLabel: String {
        switch controller.stopState {
        case .notRequested: return "Your task runs on the selected computer."
        case .requested: return "Stop requested…"
        case .receiptReceived: return "Stop received; waiting for computer state."
        case .confirmedStopped: return "Computer confirmed the session is stopped."
        case .outcomeUnknown: return "Stop outcome unknown. Reconnect to verify."
        }
    }
}

/// The budget is checked before reaching the shared parser or its cache. Local
/// chat keeps the renderer's existing behavior and defaults.
private struct RemoteHarnessAssistantText: View {
    let text: String
    let wrapsCode: Bool
    let codeTextStyle: Font.TextStyle
    var body: some View {
        if RemoteHarnessTextBudget.allowsFormatting(text) {
            MarkdownText(text: text, color: .primary, wrapsCode: wrapsCode,
                         codeTextStyle: codeTextStyle, showsCodeCopyButton: true).textSelection(.enabled)
        } else {
            RemoteHarnessRawText(text: text, textStyle: codeTextStyle, formattingLimited: true)
        }
    }
}

private struct RemoteHarnessRawText: View {
    let text: String
    let textStyle: Font.TextStyle
    var formattingLimited = false
    @State private var selectedPage = 0
    var body: some View {
        let page = RemoteHarnessRawTextPage(text, index: selectedPage)
        VStack(alignment: .leading, spacing: 8) {
            if formattingLimited {
                Text("Formatting is limited for this long or complex message. The full original text is available below.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("remote-formatting-limited")
            }
            Button { copyToPasteboard(text) } label: { Label("Copy full text", systemImage: "doc.on.doc") }
                .font(.caption).accessibilityIdentifier("remote-copy-raw-text")
            if page.count > 1 {
                HStack {
                    Button("Previous") { selectedPage = page.index - 1 }.disabled(page.index == 0)
                    Text("Page \(page.index + 1) of \(page.count)").font(.caption).foregroundStyle(.secondary)
                    Button("Next") { selectedPage = page.index + 1 }.disabled(page.index + 1 >= page.count)
                }.accessibilityIdentifier("remote-raw-text-pages")
            }
            ScrollView([.horizontal, .vertical]) {
                Text(page.text).font(.system(textStyle, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).privacySensitive()
            }.frame(maxHeight: 220)
        }
    }
}
#endif
