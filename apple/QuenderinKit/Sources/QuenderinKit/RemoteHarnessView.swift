#if canImport(SwiftUI)
import SwiftUI

/// Native computer destination; local conversations and provider keys are never
/// dependencies of this view or its controller.
public struct RemoteHarnessView: View {
    @ObservedObject private var controller: RemoteHarnessClientController
    private let showsDoneButton: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var origin = ""
    @State private var email = ""
    @State private var password = ""
    @State private var deviceName = "Quenderin"
    @State private var selectedModel = ""
    @State private var effort = ""
    public init(controller: RemoteHarnessClientController = .shared, showsDoneButton: Bool = false) {
        self.controller = controller; self.showsDoneButton = showsDoneButton
    }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let failure = controller.failure {
                    Text(failure.localizedDescription).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().accessibilityIdentifier("remote-error")
                }
                if controller.busy { ProgressView("Connecting to your computer…").padding().accessibilityIdentifier("remote-progress") }
                if !controller.companionAvailable, !controller.busy, [.workspaces, .sessions, .session].contains(controller.screen) {
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
        .onDisappear { password = "" }
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
        }
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
        VStack(spacing: 0) {
            destination.padding(.horizontal).padding(.vertical, 8)
            HStack {
                Text(controller.sessionTitle).font(.headline)
                Spacer()
                Button { Task { await controller.refreshSessionState() } } label: { Label("Refresh status", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly).disabled(controller.busy).accessibilityIdentifier("remote-refresh-status")
                if controller.running { Text("Running on computer").font(.caption) }
            }.padding(.horizontal)
            modelControls.padding(.horizontal).padding(.vertical, 6)
            Divider()
            history
            if !controller.approvals.isEmpty { approvalControls }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextField("Task for this computer", text: Binding(
                    get: { controller.journal.draft },
                    set: { value in controller.updateDraft(value) }
                ), axis: .vertical)
                    .lineLimit(2...8).textFieldStyle(.roundedBorder).accessibilityIdentifier("remote-composer")
                HStack {
                    Text(stopLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { Task { await controller.stop() } }.disabled(!controller.canStop).accessibilityIdentifier("remote-stop")
                    Button("Send") { Task { await controller.send() } }.buttonStyle(.borderedProminent).disabled(!controller.canSend).accessibilityIdentifier("remote-send")
                }
            }.padding()
        }
    }
    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if controller.timeline.hasMore { Button("Load earlier messages") { Task { await controller.loadEarlier() } }.disabled(controller.busy) }
                ForEach(controller.timeline.rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if row.kind == "reasoning" {
                            DisclosureGroup("Reasoning") { Text(row.text).textSelection(.enabled) }
                        } else { Text(row.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        if row.kind == "tool" {
                            DisclosureGroup("Tool details") { Text(String(decoding: row.raw, as: UTF8.self)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }
                    }.accessibilityIdentifier("remote-timeline-row")
                }
            }.padding().frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("remote-timeline")
    }
    private var modelControls: some View {
        HStack {
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
#endif
