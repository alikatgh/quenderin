#if canImport(Combine)
import Combine
import Foundation

@MainActor
public final class DeepSeekController: ObservableObject {
    public static let shared = DeepSeekController()
    @Published public private(set) var journal = DeepSeekJournal()
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: DeepSeekFailure?
    @Published public private(set) var notice: String?
    private let credentials: any DeepSeekCredentialStore
    private let storage: any DeepSeekJournalStorage
    private let client: DeepSeekClient
    private var work: Task<Void, Never>?
    private var activeRun: UUID?
    private var activeValidation: UUID?
    private var lastCheckpoint = Date.distantPast
    private var storageReady = true

    public init(credentials: any DeepSeekCredentialStore = DeepSeekKeychainStore(),
                storage: any DeepSeekJournalStorage = DeepSeekFileJournalStorage(), client: DeepSeekClient = DeepSeekClient()) {
        self.credentials = credentials; self.storage = storage; self.client = client
        do {
            if var loaded = try storage.load() {
                try loaded.validateAndRecover(); journal = loaded
            }
        } catch { self.error = .persistence; storageReady = false }
        if storageReady {
            do { try retirePendingCredentials() }
            catch { self.error = Self.safe(error) }
        }
    }
    public var chat: DeepSeekSavedChat? { journal.chats.first { $0.id == journal.selectedChatID } }
    public var isConnected: Bool { journal.profile != nil }
    public var model: String { chat?.envelope.selection?.modelID ?? DeepSeekContract.models[0] }
    public var effort: ProviderReasoningEffort { chat?.envelope.selection?.reasoningEffort ?? .high }
    public var canSend: Bool { storageReady && isConnected && !isBusy && chat?.state == .ready }

    public func connect(_ input: String, selectedModel: String) async {
        guard !isBusy, storageReady else { if !storageReady { error = .persistence }; return }
        isBusy = true; error = nil; notice = nil
        let validation = UUID(); activeValidation = validation
        defer { isBusy = false; activeValidation = nil }
        do {
            let key = try DeepSeekAPIKey(input)
            _ = try await client.validate(key: key, selectedModel: selectedModel, callID: validation)
            try Task.checkCancellation()
            guard activeValidation == validation else { throw CancellationError() }
            let reference = "qcred:" + UUID().uuidString
            // Persist ownership of the staged reference before any secure-store write.
            // A crash or failed journal commit can then retire it safely after relaunch.
            var prepared = journal
            prepared.pendingCredentialRemovals = (prepared.pendingCredentialRemovals ?? []) + [reference]
            try storage.save(prepared); journal = prepared
            var next = prepared
            next.pendingCredentialRemovals?.removeAll { $0 == reference }
            next.profile = try NativeConnectionProfile(id: "deepseek-default", kind: .deepseek, displayName: "DeepSeek",
                endpoint: DeepSeekContract.origin, credentialReference: reference)
            if let old = journal.profile?.credentialReference {
                next.pendingCredentialRemovals = (next.pendingCredentialRemovals ?? []) + [old]
            }
            // Never enumerate, copy, migrate, or reference the local conversation store.
            if next.selectedChatID == nil { try Self.addChat(to: &next, model: selectedModel, effort: .high) }
            do {
                try credentials.save(key, reference: reference)
                try storage.save(next)
            }
            catch {
                let original = error
                // Defensively reconcile an injected/nonconforming store that reports an
                // error after committing. Never retire a key referenced by durable state.
                try reconcileJournal()
                if journal.profile?.credentialReference == reference {
                    try retirePendingCredentials()
                    notice = "Connected. The saved connection was recovered after a storage error."
                    return
                }
                do { try retirePendingCredentials() }
                catch { self.error = Self.safe(error) }
                throw original
            }
            journal = next
            notice = "Connected. Your key is in this device’s Keychain. No inference request was made."
            try retirePendingCredentials()
        } catch is CancellationError { error = .interrupted }
        catch { self.error = Self.safe(error) }
    }

    public func removeConnection() {
        guard !isBusy, let reference = journal.profile?.credentialReference else { return }
        do {
            var next = journal; next.profile = nil
            next.pendingCredentialRemovals = (next.pendingCredentialRemovals ?? []) + [reference]
            try storage.save(next); journal = next; error = nil
            try retirePendingCredentials()
            notice = "Connection removed. Saved DeepSeek conversations remain on this device."
        } catch {
            do { try reconcileJournal() }
            catch { storageReady = false }
            self.error = Self.safe(error)
        }
    }
    private func reconcileJournal() throws {
        do {
            guard var durable = try storage.load() else { throw DeepSeekFailure.persistence }
            try durable.validateAndRecover(); journal = durable
        } catch { storageReady = false; throw DeepSeekFailure.persistence }
    }
    private func retirePendingCredentials() throws {
        for reference in journal.pendingCredentialRemovals ?? [] {
            try credentials.remove(reference: reference)
            var next = journal
            next.pendingCredentialRemovals?.removeAll { $0 == reference }
            try storage.save(next); journal = next
        }
    }
    public func newChat() {
        guard !isBusy, isConnected, storageReady else { return }
        do {
            var next = journal
            try Self.addChat(to: &next, model: model, effort: effort)
            try storage.save(next); journal = next; error = nil; notice = nil
        } catch { self.error = Self.safe(error) }
    }
    private static func addChat(to journal: inout DeepSeekJournal, model: String, effort: ProviderReasoningEffort) throws {
        guard journal.chats.count < 50 else { throw DeepSeekFailure.historyLimit }
        let envelope = try NativeConversationEnvelope(conversationID: UUID().uuidString,
            binding: NativeConversationBinding(profileID: "deepseek-default", kind: .deepseek, origin: DeepSeekContract.origin),
            selection: ProviderSelection(providerID: "deepseek", modelID: model, reasoningEffort: effort), messages: [])
        journal.chats.insert(DeepSeekSavedChat(envelope: envelope), at: 0); journal.selectedChatID = envelope.conversationID
    }
    public func selectChat(_ id: String) {
        guard !isBusy, journal.chats.contains(where: { $0.id == id }) else { return }
        var next = journal; next.selectedChatID = id
        do { try storage.save(next); journal = next; error = nil; notice = nil }
        catch { self.error = .persistence }
    }
    public func setSelection(model: String, effort: ProviderReasoningEffort) {
        guard !isBusy, DeepSeekContract.models.contains(model), let index = selectedIndex, journal.chats[index].state == .ready else { return }
        do {
            var next = journal; try next.chats[index].updateSelection(model: model, effort: effort)
            try storage.save(next); journal = next; error = nil
        } catch { self.error = Self.safe(error) }
    }

    /// The UI calls this only after explicit destination consent. One Send creates one
    /// paid request. Stop, relaunch, and errors never enqueue or retry another request.
    public func send(_ text: String) {
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = selectedIndex, let profile = journal.profile, let reference = profile.credentialReference else { return }
        do {
            let key = try credentials.load(reference: reference)
            let user = try ProviderMessage(id: UUID().uuidString, role: .user, content: text)
            let requestID = UUID().uuidString
            let saved = journal.chats[index]
            let envelope = try NativeConversationEnvelope(conversationID: saved.id, binding: saved.envelope.binding,
                selection: saved.envelope.selection, messages: saved.envelope.messages + [user])
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let request = try ProviderRequest(requestID: requestID, profile: profile, envelope: envelope,
                capabilities: DeepSeekContract.capabilities, tools: [],
                limits: ProviderRequestLimits(maxOutputTokens: DeepSeekContract.maxTokens, maxToolCalls: 0, deadlineEpochMs: now + 120_000), nowEpochMs: now)
            _ = try DeepSeekContract.body(request)
            var next = journal
            next.chats[index].pendingUser = user
            next.chats[index].partialAssistant = try ProviderMessage(id: requestID, role: .assistant, content: "")
            next.chats[index].state = .running; next.chats[index].failure = nil; next.chats[index].usage = nil
            try storage.save(next)
            journal = next; isBusy = true; error = nil; notice = nil; lastCheckpoint = .distantPast
            let run = UUID(); activeRun = run
            work = Task { [weak self, client] in
                do {
                    let result = try await client.run(request, key: key, callID: run) { [weak self] event in
                        await self?.receive(event, run: run)
                    }
                    guard let self else { return }
                    try Task.checkCancellation()
                    self.finished(result, run: run)
                } catch {
                    self?.failed(error, run: run)
                }
                guard let self else { return }
                self.isBusy = false; self.activeRun = nil; self.work = nil
            }
        } catch { self.error = Self.safe(error) }
    }
    public func stop() {
        guard isBusy else { return }
        guard let run = activeRun else {
            let validation = activeValidation
            activeValidation = nil
            if let validation { Task { [client] in await client.cancel(callID: validation) } }
            return
        }
        work?.cancel()
        failed(CancellationError(), run: run)
        Task { [client] in await client.cancel(callID: run) }
    }
    private var selectedIndex: Int? { journal.chats.firstIndex { $0.id == journal.selectedChatID } }
    private func receive(_ event: ProviderEvent, run: UUID) {
        guard activeRun == run, let index = selectedIndex, journal.chats[index].state == .running,
              let assistant = journal.chats[index].partialAssistant else { return }
        do {
            switch event {
            case .text(let value):
                journal.chats[index].partialAssistant = try ProviderMessage(id: assistant.id, role: .assistant,
                    content: assistant.content + value.delta, reasoningContent: assistant.reasoningContent)
            case .reasoning(let value):
                journal.chats[index].partialAssistant = try ProviderMessage(id: assistant.id, role: .assistant,
                    content: assistant.content, reasoningContent: (assistant.reasoningContent ?? "") + value.delta)
            case .usage(let value): journal.chats[index].usage = DeepSeekSavedUsage(value)
            case .toolCallFragment: stop(); error = .limit
            default: break
            }
            if Date().timeIntervalSince(lastCheckpoint) >= 1 {
                try storage.save(journal); lastCheckpoint = Date()
            }
        } catch { stop(); self.error = .persistence; storageReady = false }
    }
    private func finished(_ result: DeepSeekStreamAccumulator, run: UUID) {
        guard activeRun == run, let index = selectedIndex, journal.chats[index].state == .running,
              let user = journal.chats[index].pendingUser, let partial = journal.chats[index].partialAssistant else { return }
        do {
            var next = journal
            next.chats[index].usage = result.usage.map(DeepSeekSavedUsage.init)
            let assistant = try ProviderMessage(id: partial.id, role: .assistant, content: result.text,
                reasoningContent: result.reasoning.isEmpty ? nil : result.reasoning)
            if result.finishReason == .end {
                let prior = next.chats[index].envelope
                next.chats[index].envelope = try NativeConversationEnvelope(conversationID: prior.conversationID,
                    binding: prior.binding, selection: prior.selection, messages: prior.messages + [user, assistant])
                next.chats[index].pendingUser = nil; next.chats[index].partialAssistant = nil; next.chats[index].state = .ready
            } else {
                next.chats[index].partialAssistant = assistant; next.chats[index].state = .outputLimit
            }
            try storage.save(next); journal = next
        } catch { failed(DeepSeekFailure.persistence, run: run); storageReady = false }
    }
    private func failed(_ failure: Error, run: UUID) {
        guard activeRun == run, let index = selectedIndex, journal.chats[index].state == .running else { return }
        let code = Self.safe(failure)
        journal.chats[index].state = failure is CancellationError ? .cancelled : .failed
        journal.chats[index].failure = DeepSeekFailureRecord(code)
        if !(failure is CancellationError) { error = code }
        do { try storage.save(journal) }
        catch { self.error = .persistence; storageReady = false }
    }
    private static func safe(_ error: Error) -> DeepSeekFailure {
        if let error = error as? DeepSeekFailure { return error }
        if let error = error as? NativeConnectionError { return error == .limitExceeded ? .limit : .malformed }
        return error is CancellationError ? .interrupted : .connection
    }
}
#endif
