#if canImport(Combine)
import Combine
import Foundation

public enum RemoteHarnessClientScreen: String { case setup, computers, trust, workspaces, sessions, session, disconnected }

public struct RemoteHarnessClientApprovalCard: Identifiable, NativeConnectionPrivateValue {
    public var id: String { approval.eventID }
    public let approval: RemoteHarnessPendingApproval
    public let toolName: String
    public let callID: String?
    public let reason: String?
    public let metadata: String
    public let action: RemoteHarnessClientApprovalAction?
    init(_ approval: RemoteHarnessPendingApproval, action: RemoteHarnessClientApprovalAction?) {
        self.approval = approval; self.action = action
        let fields = try? approval.request.fields()
        toolName = (try? fields?.text("toolName")) ?? "Computer tool approval"
        callID = try? fields?.text("callId"); reason = try? fields?.text("reason")
        metadata = String(decoding: approval.request.data, as: UTF8.self)
    }
}

@MainActor public final class RemoteHarnessClientController: ObservableObject, RemoteHarnessCommandJournal {
    public static let shared = RemoteHarnessClientController()
    @Published public private(set) var journal = RemoteHarnessClientJournal()
    @Published public private(set) var screen: RemoteHarnessClientScreen = .setup
    @Published public private(set) var busy = false
    @Published public private(set) var failure: RemoteHarnessClientFailure?
    @Published public private(set) var hosts: [RemoteHarnessClientHost] = []
    @Published public private(set) var pendingHost: RemoteHarnessClientHost?
    @Published public private(set) var host: RemoteHarnessClientHost?
    @Published public private(set) var workspaces: [RemoteHarnessClientWorkspace] = []
    @Published public private(set) var sessions: [RemoteHarnessClientSession] = []
    @Published public private(set) var models: [RemoteHarnessClientModel] = []
    @Published public private(set) var selectedModelID = ""
    @Published public private(set) var selectedEffort = ""
    @Published public private(set) var timeline = RemoteHarnessClientTimeline()
    @Published public private(set) var stopState = RemoteHarnessStopState.notRequested
    @Published public private(set) var approvals: [RemoteHarnessPendingApproval] = []
    @Published public private(set) var approvalCards: [RemoteHarnessClientApprovalCard] = []
    @Published public private(set) var running = false
    @Published public private(set) var snapshotReady = false
    @Published public private(set) var companionAvailable = false
    @Published public private(set) var botReadAvailable = false
    @Published public private(set) var botRoster: RemoteHarnessBotRoster?
    @Published public private(set) var botLoading = false
    @Published public private(set) var botUnavailable = false
    @Published private var unsavedDraft: RemoteHarnessClientUnsavedDraft?
    private var draftEditID = UUID()
    private let backend: any RemoteHarnessCryptoBackend
    private let account: RemoteHarnessClientAccount
    private let storage: any RemoteHarnessClientJournalStorage
    private let recoveryIntent: any RemoteHarnessClientRecoveryIntentStorage
    private let makeSocket: @MainActor () -> any RemoteHarnessClientSocket
    private let clock: any RemoteHarnessClock
    private let clientTimeZone: () -> TimeZone
    private var operationID: UUID?
    private var workTask: Task<Void, Never>?
    private var snapshotDeadline: Task<Void, Never>?
    private var workspaceSnapshotWaiter: CheckedContinuation<Void, Error>?
    private var botTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var foregroundRequestID: UUID?
    private var foregroundRecoveryAllowed = true
    private var botRequestID: UUID?
    private var botBinding: RemoteHarnessBinding?
    private var sessionsBinding: RemoteHarnessBinding?
    @TaskLocal private static var taskOperationID: UUID?
    private var storageReady = true
    private var selectedWorkspace: RemoteHarnessClientWorkspace?
    private var credential: RemoteHarnessClientCredential?
    private lazy var gateway: RemoteHarnessClientGateway = {
        let value = RemoteHarnessClientGateway(backend: backend, journal: self, clock: clock, makeSocket: makeSocket)
        value.onDisconnected = { [weak self] failure in
            guard let self else { return }; self.invalidateBotContext(); self.failure = failure; self.screen = .disconnected; self.snapshotReady = false; self.companionAvailable = false
            self.workspaceSnapshotWaiter?.resume(throwing: failure); self.workspaceSnapshotWaiter = nil
            self.stopState = self.gateway.stopState; self.approvals = []; self.approvalCards = []; self.timeline.clearApprovalEvidence()
        }
        value.onStateChanged = { [weak self] in guard let self else { return }; self.stopState = self.gateway.stopState; self.approvals = self.gateway.approvals; self.companionAvailable = self.gateway.supportsCompanion; self.synchronizeBotSupport(); self.refreshApprovalCards() }
        return value
    }()
    public init(backend: (any RemoteHarnessCryptoBackend)? = nil, http: (any RemoteHarnessClientHTTP)? = nil,
                credentials: (any RemoteHarnessClientCredentialStorage)? = nil, storage: (any RemoteHarnessClientJournalStorage)? = nil,
                recoveryIntent: (any RemoteHarnessClientRecoveryIntentStorage)? = nil,
                clock: (any RemoteHarnessClock)? = nil, makeSocket: @escaping @MainActor () -> any RemoteHarnessClientSocket = { RemoteHarnessClientWebSocket() }, randomSeed: (() throws -> Data)? = nil,
                clientTimeZone: @escaping () -> TimeZone = { .current }) {
        let backend = backend ?? RemoteHarnessCryptoBackends.native(), clock = clock ?? RemoteHarnessClientSystemClock()
        self.backend = backend; self.clock = clock; self.makeSocket = makeSocket; self.clientTimeZone = clientTimeZone
        let journalStorage = storage ?? RemoteHarnessClientFileStorage()
        self.storage = journalStorage
        self.recoveryIntent = recoveryIntent ?? (journalStorage as? any RemoteHarnessClientRecoveryIntentStorage) ?? RemoteHarnessClientRecoveryPreferences()
        account = RemoteHarnessClientAccount(http: http ?? RemoteHarnessClientURLSessionHTTP(), storage: credentials ?? RemoteHarnessClientKeychainStorage(), backend: backend, clock: clock, randomSeed: randomSeed)
        do {
            if let saved = try self.storage.load() {
                try saved.validate(); journal = saved; try timeline.restore(saved.history)
                screen = saved.origin == nil ? .setup : .disconnected
            }
        } catch { storageReady = false; failure = .storage }
        do { foregroundRecoveryAllowed = try self.recoveryIntent.loadAutomaticRecoveryIntent() }
        catch { foregroundRecoveryAllowed = false; failure = .storage }
    }
    public var cryptoAvailable: Bool { backend.isAvailable }
    public var isBotSessionReadOnly: Bool {
        journal.botReadOnlyScope?.matches(origin: journal.origin, hostID: journal.profile?.hostID, hostFingerprint: journal.profile?.hostFingerprint,
            workspaceID: journal.profile?.workspaceID, sessionID: journal.sessionID) == true
    }
    public var botSessionClassificationPending: Bool { gateway.supportsBotRead && !botClassificationReady }
    private var botClassificationReady: Bool {
        !gateway.supportsBotRead || (!botLoading && !botUnavailable && botRoster != nil && Self.sameBinding(botBinding, gateway.binding))
    }
    public var canSend: Bool { storageReady && !isBotSessionReadOnly && botClassificationReady && companionAvailable && snapshotReady && screen == .session && !busy && !running && !draft(for: composerDestination).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canCreateSession: Bool { storageReady && companionAvailable && screen == .sessions && !busy }
    public var canChangeModel: Bool { storageReady && !isBotSessionReadOnly && botClassificationReady && companionAvailable && snapshotReady && screen == .session && !busy && !running }
    public var canStop: Bool { snapshotReady && screen == .session && !busy && running }
    public var workspaceTitle: String { selectedWorkspace?.title ?? journal.profile?.displayName ?? "Choose workspace" }
    public var computerName: String { host?.name ?? "Saved computer" }
    public var sessionTitle: String { sessions.first { $0.sessionID == journal.sessionID }?.title ?? "Remote session" }
    public var pendingFingerprint: String? { pendingHost?.fingerprint }
    public var clientDeviceID: String? { credential?.deviceID }
    public var clientPublicIdentity: String? { credential?.identityKey }
    public var clientFingerprint: String? {
        guard let key = credential?.identityKey, let data = try? RemoteHarnessClientEncoding.key(key) else { return nil }
        return try? RemoteHarnessClientEncoding.digest(data)
    }
    public var selectedModel: RemoteHarnessClientModel? { models.first { $0.id == selectedModelID } }
    public var composerDestination: RemoteHarnessClientComposerDestination? {
        guard let origin = journal.origin, let hostID = journal.profile?.hostID, let fingerprint = journal.profile?.hostFingerprint,
              let workspaceID = journal.profile?.workspaceID, let sessionID = journal.sessionID else { return nil }
        return .init(origin: origin, hostID: hostID, fingerprint: fingerprint, workspaceID: workspaceID, sessionID: sessionID)
    }
    public var unsavedDraftForCopy: String? { unsavedDraft?.text }
    public func draft(for destination: RemoteHarnessClientComposerDestination?) -> String {
        guard let destination, destination == composerDestination else { return "" }
        if let unsavedDraft, unsavedDraft.destination == destination { return unsavedDraft.text }
        return journal.draft
    }
    public func updateDraft(_ text: String) {
        updateDraft(text, for: composerDestination)
    }
    public func updateDraft(_ text: String, for destination: RemoteHarnessClientComposerDestination?) {
        guard let destination, destination == composerDestination else { return }
        guard text.utf8.count <= 65_536 else { failure = .limit; return }
        guard storageReady else {
            guard unsavedDraft == nil || unsavedDraft?.destination == destination else { failure = .storage; return }
            draftEditID = UUID()
            unsavedDraft = .init(destination: destination, text: text); failure = .storage; return
        }
        // Identical accepted edits are still later user intent. String equality
        // cannot distinguish them from the text captured by an earlier Send.
        draftEditID = UUID()
        var next = journal; next.draft = text
        do { try commit(next); unsavedDraft = nil }
        catch { unsavedDraft = .init(destination: destination, text: text); fail(error) }
    }
    public func submission(for destination: RemoteHarnessClientComposerDestination?) -> RemoteHarnessClientComposerSubmission? {
        guard let destination, destination == composerDestination else { return nil }
        return .init(destination: destination, text: draft(for: destination), acceptedEditID: draftEditID)
    }
    public func authorize(origin: String, email: String, password: String, deviceName: String) async {
        await work {
            guard self.cryptoAvailable else { throw RemoteHarnessClientFailure.cryptoUnavailable }
            let canonical = try NativeConnectionOrigin.canonical(origin)
            // Reauthorization keeps the existing server-bound identity and drafts.
            if let saved = self.journal.origin, saved != canonical { throw RemoteHarnessClientFailure.invalidServer }
            let credential = try await self.account.authorize(origin: canonical, email: email, password: password, deviceName: deviceName)
            try self.checkOperation()
            var next = self.journal; next.origin = canonical; next.deviceID = credential.deviceID
            try self.commit(next); self.credential = credential
            let hosts = try await self.account.hosts(credential); try self.checkOperation(); self.hosts = hosts; self.screen = .computers
        }
    }
    public func reconnect() async {
        do { try setForegroundRecoveryAllowed(true) } catch { fail(error); return }
        await work {
            self.invalidateBotContext()
            guard self.cryptoAvailable else { throw RemoteHarnessClientFailure.cryptoUnavailable }
            guard let origin = self.journal.origin, let deviceID = self.journal.deviceID else { self.screen = .setup; return }
            let credential = try await self.account.credential(origin: origin, deviceID: deviceID); self.credential = credential
            try self.checkOperation(); let hosts = try await self.account.hosts(credential); try self.checkOperation(); self.hosts = hosts
            if let target = self.recoveryHost, let summary = self.hosts.first(where: { $0.deviceID.utf8.elementsEqual(target.hostID.utf8) }) {
                let host = try await self.account.host(summary, credential: credential)
                try self.checkOperation()
                guard target.matches(host) else { throw RemoteHarnessClientFailure.pinChanged }
                self.host = host
                try await self.connect(workspaceID: nil, sessionID: nil)
                if let workspaceID = self.journal.profile?.workspaceID, let workspace = self.workspaces.first(where: { $0.workspaceID.utf8.elementsEqual(workspaceID.utf8) }), let sessionID = self.journal.sessionID, workspace.sessionIDs.contains(where: { $0.utf8.elementsEqual(sessionID.utf8) }) {
                    self.selectedWorkspace = workspace; try await self.openSession(sessionID)
                } else { self.screen = .workspaces }
            } else { self.screen = .computers }
        }
    }
    /// Coalesces scene/window activation. Reuse a healthy stream; only a closed
    /// generation recovers through the existing pinned-Host path. Recovery reads
    /// authoritative history and never replays the protected command journal.
    public func reconcileForeground() async {
        if let foregroundTask { await foregroundTask.value; return }
        guard foregroundRecoveryAllowed, !busy, storageReady,
              [.workspaces, .sessions, .session, .disconnected].contains(screen),
              let target = recoveryHost, journal.pins[target.hostID]?.utf8.elementsEqual(target.fingerprint.utf8) == true else { return }
        if let host, !target.matches(host) { return }
        gateway.reconcileForeground()
        guard screen == .disconnected, gateway.binding == nil else { return }
        let requestID = UUID()
        foregroundRequestID = requestID
        let task = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await self.reconnect()
        }
        foregroundTask = task
        await task.value
        if foregroundRequestID == requestID { foregroundTask = nil; foregroundRequestID = nil }
    }
    public func selectHost(_ summary: RemoteHarnessClientHost) async {
        await work {
            self.invalidateBotContext()
            guard let origin = self.journal.origin, let deviceID = self.journal.deviceID else { throw RemoteHarnessClientFailure.reauthorize }
            let credential = try await self.account.credential(origin: origin, deviceID: deviceID); try self.checkOperation(); self.credential = credential
            let candidate = try await self.account.host(summary, credential: credential)
            try self.checkOperation()
            guard let fingerprint = candidate.fingerprint else { throw RemoteHarnessClientFailure.cryptoUnavailable }
            if let pin = self.journal.pins[candidate.deviceID] {
                guard pin.utf8.elementsEqual(fingerprint.utf8) else { throw RemoteHarnessClientFailure.pinChanged }
                try self.checkpointHostSelection(candidate)
                self.host = candidate; try self.setForegroundRecoveryAllowed(true); try await self.connect(workspaceID: nil, sessionID: nil); self.screen = .workspaces
            } else { try self.setForegroundRecoveryAllowed(false); self.pendingHost = candidate; self.screen = .trust }
        }
    }
    public func trustHost() async {
        await work {
            guard let host = self.pendingHost, let fingerprint = host.fingerprint else { throw RemoteHarnessClientFailure.protocolMismatch }
            var next = self.journal; next.pins[host.deviceID] = fingerprint
            try self.checkpointHostSelection(host, journal: next)
            self.host = host; self.pendingHost = nil
            try self.setForegroundRecoveryAllowed(true)
            try await self.connect(workspaceID: nil, sessionID: nil); self.screen = .workspaces
        }
    }
    public func selectWorkspace(_ workspace: RemoteHarnessClientWorkspace) async {
        await work { try await self.openWorkspace(workspace) }
    }
    private func openWorkspace(_ workspace: RemoteHarnessClientWorkspace) async throws {
        invalidateBotContext()
        guard workspaces.contains(where: { $0.workspaceID.utf8.elementsEqual(workspace.workspaceID.utf8) }), let host,
              let fingerprint = host.fingerprint, let origin = journal.origin else { throw RemoteHarnessClientFailure.protocolMismatch }
        let profile = try NativeConnectionProfile(id: "remote-" + UUID().uuidString.lowercased(), kind: .remoteHarness, displayName: workspace.title,
            endpoint: origin, hostID: host.deviceID, hostFingerprint: fingerprint, workspaceID: workspace.workspaceID)
        var next = journal; try preserveSession(&next); next.profile = profile; next.sessionID = nil; next.botReadOnlyScope = nil; next.history = []; next.draft = ""
        try commit(next); selectedWorkspace = workspace
        try await connect(workspaceID: workspace.workspaceID, sessionID: nil)
        guard let fresh = workspaces.first(where: { $0.workspaceID.utf8.elementsEqual(workspace.workspaceID.utf8) }) else { throw RemoteHarnessClientFailure.protocolMismatch }
        selectedWorkspace = fresh; sessions = try await sessionList().filter { row in fresh.sessionIDs.contains { $0.utf8.elementsEqual(row.sessionID.utf8) } }; sessionsBinding = gateway.binding; screen = .sessions
        beginBotRefresh()
    }
    public func createSession() async {
        await work {
            try self.requireCompanion()
            guard let workspace = self.selectedWorkspace else { throw RemoteHarnessClientFailure.protocolMismatch }
            let result = try await self.gateway.call(.sessionCreate(workspaceID: workspace.workspaceID), commandID: UUID().uuidString)
            try self.checkOperation()
            guard let result else { throw RemoteHarnessClientFailure.protocolMismatch }
            let sessionID = try result.fields().text("sessionId")
            // Creation is the authoritative membership response for the new ID.
            self.sessions = try await self.sessionList().filter { workspace.sessionIDs.contains($0.sessionID) || $0.sessionID == sessionID }
            guard self.sessions.contains(where: { $0.sessionID == sessionID }) else { throw RemoteHarnessClientFailure.protocolMismatch }
            try await self.openSession(sessionID)
        }
    }
    public func selectSession(_ session: RemoteHarnessClientSession) async {
        await selectSession(session, bot: nil)
    }
    private func selectSession(_ session: RemoteHarnessClientSession, bot: RemoteHarnessBot?) async {
        await work {
            if let bot { guard self.currentBotSession(bot) != nil else { return } }
            guard self.sessions.contains(where: { $0.sessionID.utf8.elementsEqual(session.sessionID.utf8) }) else { throw RemoteHarnessClientFailure.protocolMismatch }
            try await self.openSession(session.sessionID, botReadOnly: bot != nil)
        }
    }
    public func canOpenBot(_ bot: RemoteHarnessBot) -> Bool { currentBotSession(bot) != nil }
    public func openBotSession(_ bot: RemoteHarnessBot) async {
        guard let session = currentBotSession(bot) else { return }
        await selectSession(session, bot: bot)
    }
    private func openSession(_ sessionID: String, botReadOnly: Bool = false) async throws {
        guard let workspaceID = journal.profile?.workspaceID else { throw RemoteHarnessClientFailure.protocolMismatch }
        var next = journal; try preserveSession(&next)
        let scope = try sessionScope(sessionID, journal: next)
        let saved = next.savedSessions.first { $0.hostID.utf8.elementsEqual(scope.hostID.utf8) && $0.workspaceID.utf8.elementsEqual(workspaceID.utf8) && $0.sessionID.utf8.elementsEqual(sessionID.utf8) }
        let readOnly = botReadOnly || scopeMatches(next.botReadOnlyScope, scope) || scopeMatches(saved?.botReadOnlyScope, scope) || rosterContainsSession(sessionID)
        next.sessionID = sessionID; next.draft = saved?.draft ?? ""; next.history = saved?.history ?? []
        next.botReadOnlyScope = readOnly ? scope : nil
        try commit(next); try timeline.restore(next.history)
        snapshotReady = false; try await connect(workspaceID: workspaceID, sessionID: sessionID)
        guard let workspace = workspaces.first(where: { $0.workspaceID.utf8.elementsEqual(workspaceID.utf8) }), workspace.sessionIDs.contains(where: { $0.utf8.elementsEqual(sessionID.utf8) }) else { throw RemoteHarnessClientFailure.protocolMismatch }
        selectedWorkspace = workspace
        let listed = try await sessionList()
        try checkOperation()
        let matchingSessions = listed.filter { $0.sessionID.utf8.elementsEqual(sessionID.utf8) }
        guard matchingSessions.count == 1, let session = matchingSessions.first else { throw RemoteHarnessClientFailure.protocolMismatch }
        running = session.running; sessions = listed.filter { row in workspace.sessionIDs.contains { $0.utf8.elementsEqual(row.sessionID.utf8) } }; sessionsBinding = gateway.binding
        beginBotRefresh()
        try await loadModels()
        let binding = gateway.binding
        try gateway.follow({ try .sessionFollow(streamID: $0, sessionID: sessionID) }) { [weak self] update in
            guard let self, self.gateway.binding == binding else { return }
            do {
                guard case .value(let value?) = update else { throw RemoteHarnessClientFailure.connection }
                if try value.fields().text("type") == "snapshot" {
                    guard try value.fields().required("header").fields().text("id").utf8.elementsEqual(sessionID.utf8) else { throw RemoteHarnessClientFailure.protocolMismatch }
                }
                try self.timeline.receive(value, expectedSessionID: sessionID)
                let type = try value.fields().text("type")
                if type == "snapshot" { self.snapshotDeadline?.cancel(); self.snapshotDeadline = nil; self.snapshotReady = true; self.screen = .session }
                // Durable records checkpoint independently from transient deltas.
                var next = self.journal; next.history = self.timeline.records; try self.commit(next)
                self.applyRunning(value)
            } catch { self.invalidateBotContext(); self.fail(error); self.gateway.disconnect(); self.screen = .disconnected; self.snapshotReady = false }
        }
        try gateway.follow({ try .control(streamID: $0) }) { [weak self] update in
            guard let self, self.gateway.binding == binding else { return }
            if case .value(let value?) = update { self.applyControl(value) }
        }
        try gateway.follow({ try .events(streamID: $0) }) { _ in }
        waitForSnapshot(binding)
    }
    public func send() async {
        guard let submission = submission(for: composerDestination) else { return }
        await send(submission)
    }
    public func send(_ submission: RemoteHarnessClientComposerSubmission) async {
        guard submission.destination == composerDestination else { return }
        guard !isBotSessionReadOnly, botClassificationReady else { return }
        guard companionAvailable else { failure = .companionRequired; return }
        guard canSend, !submission.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, submission.text.utf8.count <= 65_536 else { return }
        let sessionID = submission.destination.sessionID, text = submission.text, commandID = UUID().uuidString
        await work {
            guard submission.destination == self.composerDestination, !self.isBotSessionReadOnly, self.botClassificationReady else { return }
            try self.requireCompanion()
            let timeZone = Self.promptTimeZoneIdentifier(self.clientTimeZone().identifier)
            _ = try await self.gateway.call(.prompt(commandID: commandID, sessionID: sessionID, text: text, clientTimeZone: timeZone), commandID: commandID)
            try self.checkOperation()
            if submission.destination == self.composerDestination, self.draftEditID == submission.acceptedEditID {
                var next = self.journal; next.draft = ""; try self.commit(next); self.draftEditID = UUID()
            }
            let listed = try await self.sessionList(); try self.checkOperation()
            // An earlier list receipt cannot erase a validated live turn that
            // has already arrived on session/follow while prompt was pending.
            if let session = listed.first(where: { $0.sessionID == sessionID }) { self.running = session.running || self.timeline.hasActiveTurn }
        }
    }
    /// Foundation reports zero-offset system zones as GMT, whereas the remote
    /// contract uses UTC. Unsupported fixed-offset/abbreviation identifiers are
    /// omitted from this optional field rather than blocking a valid task.
    static func promptTimeZoneIdentifier(_ value: String) -> String? {
        if value == "GMT" || value == "UTC" { return "UTC" }
        guard value.utf8.count <= 128, value.range(of: #"^[A-Za-z_]+/[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    public func stop() async {
        guard screen == .session, let sessionID = journal.sessionID, !busy else { return }
        await work {
            _ = try await self.gateway.call(.cancel(sessionID: sessionID), commandID: UUID().uuidString)
            let listed = try await self.sessionList()
            try self.checkOperation()
            if let session = listed.first(where: { $0.sessionID == sessionID }) { self.running = session.running }
            self.stopState = self.gateway.stopState
        }
    }
    public func selectModel(_ id: String, effort: String) async {
        guard !isBotSessionReadOnly, botClassificationReady else { return }
        guard let model = models.first(where: { $0.id == id }), let sessionID = journal.sessionID, model.efforts.contains(effort) || effort.isEmpty else { return }
        await work {
            guard !self.isBotSessionReadOnly, self.botClassificationReady else { return }
            try self.requireCompanion()
            let response = try await self.gateway.call(.selectModel(sessionID: sessionID, provider: model.provider, model: model.model, reasoningEffort: effort.isEmpty ? nil : effort), commandID: UUID().uuidString)
            try self.checkOperation()
            guard let selected = try response?.fields().required("selected").fields(), try selected.text("provider") == model.provider, try selected.text("model") == model.model else { throw RemoteHarnessClientFailure.protocolMismatch }
            self.selectedModelID = model.id; self.selectedEffort = try selected["reasoningEffort"]?.stringValue() ?? ""
        }
    }
    public func loadEarlier() async {
        guard let sessionID = journal.sessionID, let through = timeline.cursor, let before = timeline.earliestSequence, timeline.hasMore else { return }
        await work {
            guard let page = try await self.gateway.call(.page(sessionID: sessionID, throughSeq: through, beforeSeq: before)) else { throw RemoteHarnessClientFailure.protocolMismatch }
            try self.checkOperation()
            try self.timeline.prependPage(page); var next = self.journal; next.history = self.timeline.records; try self.commit(next)
        }
    }
    /// Explicit user intent; transport/lifecycle teardown must not call this.
    public func disconnect() {
        foregroundRecoveryAllowed = false
        do { try recoveryIntent.saveAutomaticRecoveryIntent(false) } catch { fail(error) }
        tearDownConnection()
    }
    private func tearDownConnection() { foregroundRequestID = nil; foregroundTask?.cancel(); foregroundTask = nil; invalidateBotContext(); operationID = nil; workTask?.cancel(); workTask = nil; busy = false; snapshotDeadline?.cancel(); snapshotDeadline = nil; workspaceSnapshotWaiter?.resume(throwing: RemoteHarnessClientFailure.connection); workspaceSnapshotWaiter = nil; gateway.disconnect(); screen = journal.origin == nil ? .setup : .disconnected; snapshotReady = false; companionAvailable = false; approvals = []; approvalCards = []; timeline.clearApprovalEvidence() }
    public func showSetup() { tearDownConnection(); screen = .setup; failure = nil }
    public func showComputers() { tearDownConnection(); screen = .computers }
    /// Read state has its own task and error surface so refresh cannot disable
    /// Stop, consume an approval, or replace a draft/history failure.
    public func refreshBots() async {
        beginBotRefresh()
        await botTask?.value
    }
    private func beginBotRefresh() {
        synchronizeBotSupport()
        guard !botLoading, botReadAvailable, let binding = gateway.binding,
              Self.sameBinding(binding, sessionsBinding), let workspaceID = binding.workspaceID,
              let profileWorkspaceID = journal.profile?.workspaceID, profileWorkspaceID.utf8.elementsEqual(workspaceID.utf8) else { return }
        let requestID = UUID()
        botRequestID = requestID; botBinding = binding; botLoading = true; botUnavailable = false
        botTask = Task { [weak self] in
            guard let self else { return }
            do {
                let roster = try await self.gateway.readBotRoster()
                guard !Task.isCancelled, self.botRequestID == requestID,
                      Self.sameBinding(binding, self.gateway.binding), self.gateway.supportsBotRead,
                      roster.workspaceID.utf8.elementsEqual(workspaceID.utf8) else { return }
                try self.markSelectedBotSession(roster)
                self.botRoster = roster; self.botLoading = false; self.botTask = nil; self.botRequestID = nil
            } catch {
                guard !Task.isCancelled, self.botRequestID == requestID,
                      Self.sameBinding(binding, self.gateway.binding), self.gateway.supportsBotRead else { return }
                self.botRoster = nil; self.botLoading = false; self.botUnavailable = true; self.botTask = nil; self.botRequestID = nil
            }
        }
    }
    private func synchronizeBotSupport() {
        if !gateway.supportsBotRead || (botBinding != nil && !Self.sameBinding(botBinding, gateway.binding)) { clearBots() }
        botReadAvailable = gateway.supportsBotRead
    }
    private func clearBots() {
        botRequestID = nil; botTask?.cancel(); botTask = nil; botBinding = nil
        botRoster = nil; botReadAvailable = false; botLoading = false; botUnavailable = false
    }
    private func invalidateBotContext() { clearBots(); sessionsBinding = nil }
    private func sessionScope(_ sessionID: String, journal: RemoteHarnessClientJournal) throws -> RemoteHarnessClientBotSessionScope {
        guard let origin = journal.origin, let hostID = journal.profile?.hostID, let fingerprint = journal.profile?.hostFingerprint,
              let workspaceID = journal.profile?.workspaceID else { throw RemoteHarnessClientFailure.protocolMismatch }
        return .init(origin: origin, hostID: hostID, hostFingerprint: fingerprint, workspaceID: workspaceID, sessionID: sessionID)
    }
    private func scopeMatches(_ lhs: RemoteHarnessClientBotSessionScope?, _ rhs: RemoteHarnessClientBotSessionScope) -> Bool {
        lhs?.matches(origin: rhs.origin, hostID: rhs.hostID, hostFingerprint: rhs.hostFingerprint, workspaceID: rhs.workspaceID, sessionID: rhs.sessionID) == true
    }
    private func rosterContainsSession(_ sessionID: String) -> Bool {
        guard let roster = botRoster, Self.sameBinding(botBinding, gateway.binding),
              let workspaceID = journal.profile?.workspaceID, roster.workspaceID.utf8.elementsEqual(workspaceID.utf8) else { return false }
        return roster.bots.contains { $0.sessionID.utf8.elementsEqual(sessionID.utf8) }
    }
    private func markSelectedBotSession(_ roster: RemoteHarnessBotRoster) throws {
        guard let sessionID = journal.sessionID, let binding = gateway.binding,
              binding.sessionID?.utf8.elementsEqual(sessionID.utf8) == true,
              roster.bots.contains(where: { $0.sessionID.utf8.elementsEqual(sessionID.utf8) }) else { return }
        let scope = try sessionScope(sessionID, journal: journal)
        guard !scopeMatches(journal.botReadOnlyScope, scope) else { return }
        var next = journal; next.botReadOnlyScope = scope
        do { try commit(next) }
        catch { storageReady = false; failure = .storage; throw RemoteHarnessClientFailure.storage }
    }
    private static func sameBinding(_ lhs: RemoteHarnessBinding?, _ rhs: RemoteHarnessBinding?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.generation == rhs.generation && lhs.hostID.utf8.elementsEqual(rhs.hostID.utf8)
            && lhs.workspaceID.map { Data($0.utf8) } == rhs.workspaceID.map { Data($0.utf8) }
            && lhs.sessionID.map { Data($0.utf8) } == rhs.sessionID.map { Data($0.utf8) }
            && lhs.clientDeviceID.map { Data($0.utf8) } == rhs.clientDeviceID.map { Data($0.utf8) }
    }
    private func currentBotSession(_ bot: RemoteHarnessBot) -> RemoteHarnessClientSession? {
        guard botReadAvailable, !botUnavailable, let roster = botRoster, let binding = gateway.binding,
              Self.sameBinding(botBinding, binding), Self.sameBinding(sessionsBinding, binding),
              let workspaceID = binding.workspaceID, roster.workspaceID.utf8.elementsEqual(workspaceID.utf8),
              let profileWorkspaceID = journal.profile?.workspaceID, profileWorkspaceID.utf8.elementsEqual(workspaceID.utf8) else { return nil }
        let currentBots = roster.bots.filter { $0.id.utf8.elementsEqual(bot.id.utf8) }
        guard currentBots.count == 1, let current = currentBots.first, current.sessionID.utf8.elementsEqual(bot.sessionID.utf8) else { return nil }
        let currentWorkspaces = workspaces.filter { $0.workspaceID.utf8.elementsEqual(workspaceID.utf8) }
        guard currentWorkspaces.count == 1, currentWorkspaces[0].sessionIDs.contains(where: { $0.utf8.elementsEqual(current.sessionID.utf8) }) else { return nil }
        let currentSessions = sessions.filter { $0.sessionID.utf8.elementsEqual(current.sessionID.utf8) }
        return currentSessions.count == 1 ? currentSessions[0] : nil
    }
    public func refreshSessionState() async {
        await work {
            let listed = try await self.sessionList(); try self.checkOperation()
            if let current = listed.first(where: { $0.sessionID == self.journal.sessionID }) { self.running = current.running }
        }
    }
    public func decide(_ approval: RemoteHarnessPendingApproval, allow: Bool) async {
        guard let binding = approval.extensionBinding, approvalAction(for: approval) != nil else { return }
        await work {
            // Recheck after work's task boundary. A stale card, turn closure or
            // conflicting durable call must fail before journal/port callbacks.
            guard self.approvalAction(for: approval) != nil else { return }
            _ = try await self.gateway.call(.boundApproval(clientID: approval.clientID, binding: binding, allow: allow), commandID: UUID().uuidString)
            try self.checkOperation()
        }
    }
    public func approvalAction(for approval: RemoteHarnessPendingApproval) -> RemoteHarnessClientApprovalAction? {
        guard snapshotReady, screen == .session, gateway.binding == approval.binding,
              gateway.approvals.contains(approval) else { return nil }
        return timeline.approvalAction(for: approval)
    }
    private func refreshApprovalCards() {
        approvalCards = approvals.map { RemoteHarnessClientApprovalCard($0, action: approvalAction(for: $0)) }
    }
    private func connect(workspaceID: String?, sessionID: String?) async throws {
        invalidateBotContext()
        timeline.clearApprovalEvidence(); approvalCards = []
        companionAvailable = false
        guard let origin = journal.origin, let deviceID = journal.deviceID, let host else { throw RemoteHarnessClientFailure.reauthorize }
        let credential = try await account.credential(origin: origin, deviceID: deviceID); self.credential = credential
        try checkOperation()
        try await gateway.connect(credential: credential, host: host, workspaceID: workspaceID, sessionID: sessionID)
        try checkOperation()
        _ = try await sessionList() // Reconcile before reopening any stream on a new generation.
        try await workspaceSnapshot() // The Host companion binds membership on EACH connection.
        try checkOperation()
    }
    private func sessionList() async throws -> [RemoteHarnessClientSession] {
        guard let result = try await gateway.call(.sessionList()) else { throw RemoteHarnessClientFailure.protocolMismatch }
        try checkOperation()
        return try result.fields().required("items").elements().map { try RemoteHarnessClientSession($0) }
    }
    private func workspaceSnapshot() async throws {
        let binding = gateway.binding
        try await withCheckedThrowingContinuation { continuation in
        workspaceSnapshotWaiter = continuation
        do { try gateway.follow({ try .workspaceFollow(streamID: $0) }) { [weak self] update in
            guard let self, self.gateway.binding == binding else { return }
            do {
                guard case .value(let value?) = update else { throw RemoteHarnessClientFailure.connection }
                let f = try value.fields(), type = try f.text("type")
                if type == "baseline" || type == "replace" {
                    self.workspaces = try f.required("value").fields().required("items").elements().map { try RemoteHarnessClientWorkspace($0) }
                    self.snapshotDeadline?.cancel(); self.snapshotDeadline = nil
                    self.workspaceSnapshotWaiter?.resume(); self.workspaceSnapshotWaiter = nil
                } else if type == "upsert" {
                    let workspace = try RemoteHarnessClientWorkspace(f.required("workspace")); self.workspaces.removeAll { $0.workspaceID == workspace.workspaceID }; self.workspaces.append(workspace)
                } else if type == "remove" {
                    let id = try f.text("workspaceId"); self.workspaces.removeAll { $0.workspaceID == id }
                } else if !["order", "archived", "pinned"].contains(type) { throw RemoteHarnessClientFailure.protocolMismatch }
                guard self.workspaces.count <= 1024, Set(self.workspaces.map(\.workspaceID)).count == self.workspaces.count else { throw RemoteHarnessClientFailure.protocolMismatch }
                if let scopedWorkspace = binding?.workspaceID {
                    guard let workspace = self.workspaces.first(where: { $0.workspaceID == scopedWorkspace }),
                          binding?.sessionID == nil || workspace.sessionIDs.contains(binding!.sessionID!) else { throw RemoteHarnessClientFailure.protocolMismatch }
                }
            } catch {
                self.workspaceSnapshotWaiter?.resume(throwing: error); self.workspaceSnapshotWaiter = nil
                self.invalidateBotContext(); self.fail(error); self.gateway.disconnect(); self.screen = .disconnected
            }
        } } catch { workspaceSnapshotWaiter?.resume(throwing: error); workspaceSnapshotWaiter = nil; return }
        waitForSnapshot(binding)
        }
    }
    private func loadModels() async throws {
        guard let result = try await gateway.call(.modelCatalog()) else { throw RemoteHarnessClientFailure.protocolMismatch }
        try checkOperation()
        let f = try result.fields(), selected = try f.required("default").fields()
        models = try f.required("groups").elements().flatMap { group in
            let g = try group.fields(), provider = try g.text("id")
            return try g.required("models").elements().map { model in
                let m = try model.fields()
                let efforts = try m["reasoning"]?.fields()["efforts"]?.elements().map { try $0.fields().text("id") } ?? []
                return RemoteHarnessClientModel(provider: provider, model: try m.text("id"), name: try m.text("name"), efforts: efforts)
            }
        }
        selectedModelID = try selected.text("provider") + ":" + selected.text("model"); selectedEffort = try selected["reasoningEffort"]?.stringValue() ?? ""
    }
    private func applyControl(_ value: RemoteHarnessJSON) {
        guard let f = try? value.fields(), let type = try? f.text("type") else { return }
        if type == "baseline", let sessionID = journal.sessionID,
           let projections = try? f.required("value").fields().required("projections").fields(),
           let block = try? projections[sessionID]?.fields(), let values = try? block.required("values").fields(), let model = values["modelSelection"] {
            applyModelProjection(model)
        }
        if type == "projection", (try? f.text("sessionId")) == journal.sessionID, (try? f.text("key")) == "modelSelection", let value = f["value"] { applyModelProjection(value) }
    }
    private func applyModelProjection(_ value: RemoteHarnessJSON) {
        guard let f = try? value.fields(), let selection = (try? f["next"]?.fields()) ?? (try? f["lastUsed"]?.fields()),
              let provider = try? selection.text("provider"), let model = try? selection.text("model") else { return }
        selectedModelID = provider + ":" + model; selectedEffort = (try? selection["reasoningEffort"]?.stringValue()) ?? ""
    }
    private func applyRunning(_ value: RemoteHarnessJSON) {
        // This is called only after timeline.receive validated this generation's
        // session header, durable sequence and assistant revision/index.
        guard let f = try? value.fields(), let type = try? f.text("type") else { return }
        func turnState(_ record: RemoteHarnessJSON) -> Bool? {
            guard let item = try? record.fields(), (try? item.text("type")) == "event",
                  let event = try? item.required("event").fields(), let name = try? event.text("type") else { return nil }
            if name == "turn/start" { return true }
            if name == "turn/end" { return false }
            return nil
        }
        if type == "snapshot" {
            // A turn can be waiting for a tool without an active assistant
            // attempt. Replay the ordered lifecycle records before applying
            // the snapshot's more recent active attempt.
            if let records = try? f.required("records").elements() {
                for record in records { if let state = turnState(record) { running = state } }
            }
            if let stream = try? f["assistantStream"]?.fields(), (try? stream["activeAttempt"]?.fields()) != nil { running = true }
        } else if type == "event", let state = turnState(value) { running = state }
        else if type == "assistant-stream", let frame = try? f.required("frame").fields(), (try? frame.text("type")) == "start" {
            running = true
        }
        // An assistant attempt ending does not finish its enclosing turn;
        // tools may still be running. Only authoritative turn/end clears it.
    }
    private func work(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy, storageReady else { if !storageReady { failure = .storage }; return }
        busy = true; failure = nil; let id = UUID(); operationID = id
        let task = Task { [weak self] in
            do { try await Self.$taskOperationID.withValue(id) { try Task.checkCancellation(); try await action() } }
            catch { if self?.operationID == id { self?.fail(error) } }
        }
        workTask = task; await task.value
        if operationID == id { busy = false; operationID = nil; workTask = nil }
    }
    private func checkOperation() throws {
        guard let current = Self.taskOperationID, operationID == current else { throw CancellationError() }
    }
    private func requireCompanion() throws {
        guard companionAvailable, gateway.supportsCompanion, gateway.binding != nil else { throw RemoteHarnessClientFailure.companionRequired }
    }
    private func fail(_ error: Error) {
        if let value = error as? RemoteHarnessClientFailure { failure = value }
        else if let value = error as? RemoteHarnessError {
            switch value {
            case .journalUnavailable: failure = .storage
            case .outcomeUnknown: failure = .unknownOutcome
            case .deadlineExceeded: failure = .timeout
            case .disconnected: failure = .connection
            default: failure = .protocolMismatch
            }
        } else { failure = error is RemoteHarnessCryptoError ? .cryptoUnavailable : error is NativeConnectionError ? .invalidServer : .protocolMismatch }
        if failure == .storage { storageReady = false }
        if failure == .reauthorize { screen = .setup }
    }
    private func waitForSnapshot(_ binding: RemoteHarnessBinding?) {
        snapshotDeadline?.cancel()
        snapshotDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            guard let self, self.gateway.binding == binding else { return }
            self.workspaceSnapshotWaiter?.resume(throwing: RemoteHarnessClientFailure.timeout); self.workspaceSnapshotWaiter = nil
            self.invalidateBotContext(); self.gateway.disconnect(); self.failure = .timeout; self.screen = .disconnected; self.snapshotReady = false
        }
    }
    private func commit(_ next: RemoteHarnessClientJournal) throws {
        let previousDestination = composerDestination
        try storage.save(next); journal = next
        if previousDestination != composerDestination { draftEditID = UUID() }
    }
    private var recoveryHost: RemoteHarnessClientRecoveryHost? {
        if let target = journal.recoveryHost { return target }
        guard let hostID = journal.profile?.hostID, let fingerprint = journal.profile?.hostFingerprint else { return nil }
        return .init(hostID: hostID, fingerprint: fingerprint)
    }
    private func setForegroundRecoveryAllowed(_ allowed: Bool) throws {
        try recoveryIntent.saveAutomaticRecoveryIntent(allowed); foregroundRecoveryAllowed = allowed
    }
    private func checkpointHostSelection(_ host: RemoteHarnessClientHost, journal supplied: RemoteHarnessClientJournal? = nil) throws {
        guard let fingerprint = host.fingerprint else { throw RemoteHarnessClientFailure.cryptoUnavailable }
        var next = supplied ?? journal
        try preserveSession(&next)
        next.recoveryHost = .init(hostID: host.deviceID, fingerprint: fingerprint)
        next.profile = nil; next.sessionID = nil; next.botReadOnlyScope = nil; next.history = []; next.draft = ""
        try commit(next)
        // Retire the old session before the next credential await can allow an
        // old stream callback to write history into the new discovery target.
        gateway.disconnect(); snapshotReady = false; companionAvailable = false; running = false
        approvals = []; approvalCards = []; try timeline.restore([]); selectedWorkspace = nil; sessions = []
    }
    private func preserveSession(_ next: inout RemoteHarnessClientJournal) throws {
        guard let hostID = next.profile?.hostID, let workspaceID = next.profile?.workspaceID, let sessionID = next.sessionID else { return }
        let saved = RemoteHarnessClientSavedSession(hostID: hostID, workspaceID: workspaceID, sessionID: sessionID, draft: next.draft, history: next.history, botReadOnlyScope: next.botReadOnlyScope)
        if let index = next.savedSessions.firstIndex(where: { $0.hostID.utf8.elementsEqual(hostID.utf8) && $0.workspaceID.utf8.elementsEqual(workspaceID.utf8) && $0.sessionID.utf8.elementsEqual(sessionID.utf8) }) { next.savedSessions[index] = saved }
        else { guard next.savedSessions.count < 50 else { throw RemoteHarnessClientFailure.limit }; next.savedSessions.append(saved) }
    }
    public func persistBeforeDispatch(_ command: RemoteHarnessJournalCommand) throws {
        guard !journal.commands.contains(where: { $0.id == command.commandID }), journal.commands.count < 4096 else { throw RemoteHarnessError.duplicateCommand }
        var next = journal
        next.commands.append(.init(id: command.commandID, hostID: command.binding.hostID, workspaceID: command.binding.workspaceID, sessionID: command.binding.sessionID,
            endpoint: command.operation.endpoint ?? "", params: command.operation.params.data, outcome: "prepared"))
        try commit(next)
    }
    public func recordOutcome(commandID: String, outcome: RemoteHarnessJournalOutcome) throws {
        guard let index = journal.commands.firstIndex(where: { $0.id == commandID }) else { throw RemoteHarnessClientFailure.storage }
        var next = journal; next.commands[index].outcome = outcome.rawValue; try commit(next)
    }
}
#endif
