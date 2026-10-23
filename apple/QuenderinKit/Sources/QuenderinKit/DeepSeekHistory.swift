import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DeepSeekTurnState: String, Codable, Sendable { case ready, running, interrupted, cancelled, failed, outputLimit }

public struct DeepSeekSavedUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    init(_ value: ProviderUsage) { inputTokens = value.inputTokens; outputTokens = value.outputTokens }
}

/// Completed provider history and the unfinished turn are separate on disk as well as in
/// memory. An interrupted user/assistant pair can never silently become a new paid request.
public struct DeepSeekSavedChat: Codable, Sendable, Identifiable, NativeConnectionPrivateValue {
    public var id: String { envelope.conversationID }
    public var envelope: NativeConversationEnvelope
    public var pendingUser: ProviderMessage?
    public var partialAssistant: ProviderMessage?
    public var state: DeepSeekTurnState
    public var usage: DeepSeekSavedUsage?
    public var failure: DeepSeekFailureRecord?
    public init(envelope: NativeConversationEnvelope) {
        self.envelope = envelope; state = .ready
    }
    public var title: String { String((envelope.messages.first?.content ?? pendingUser?.content ?? "New DeepSeek chat").prefix(60)) }
    public var displayedMessages: [ProviderMessage] { envelope.messages + [pendingUser, partialAssistant].compactMap { $0 } }
    mutating func updateSelection(model: String, effort: ProviderReasoningEffort) throws {
        envelope = try NativeConversationEnvelope(conversationID: id, binding: envelope.binding,
            selection: ProviderSelection(providerID: "deepseek", modelID: model, reasoningEffort: effort), messages: envelope.messages)
    }
}

/// Store only known fixed codes, never a provider body or system error description.
public struct DeepSeekFailureRecord: Codable, Sendable {
    public let code: String
    init(_ failure: DeepSeekFailure) { code = failure.rawValue }
    public var failure: DeepSeekFailure { DeepSeekFailure(rawValue: code) ?? .interrupted }
}

public struct DeepSeekJournal: Codable, Sendable, NativeConnectionPrivateValue {
    public let schemaVersion: Int
    public var profile: NativeConnectionProfile?
    public var chats: [DeepSeekSavedChat]
    public var selectedChatID: String?
    /// Only opaque references, retained until secure-store retirement succeeds.
    public var pendingCredentialRemovals: [String]?
    public init() { schemaVersion = 1; chats = []; pendingCredentialRemovals = [] }

    public mutating func validateAndRecover() throws {
        guard schemaVersion == 1, chats.count <= 50, Set(chats.map(\.id)).count == chats.count else { throw DeepSeekFailure.persistence }
        let removals = pendingCredentialRemovals ?? []
        guard removals.count <= 128, Set(removals).count == removals.count,
              removals.allSatisfy({ $0.hasPrefix("qcred:") && UUID(uuidString: String($0.dropFirst(6))) != nil }),
              profile?.credentialReference.map({ !removals.contains($0) }) ?? true else { throw DeepSeekFailure.persistence }
        if let profile {
            guard profile.id == "deepseek-default", profile.kind == .deepseek, profile.endpoint == DeepSeekContract.origin,
                  let reference = profile.credentialReference, reference.hasPrefix("qcred:"),
                  UUID(uuidString: String(reference.dropFirst(6))) != nil else { throw DeepSeekFailure.persistence }
        }
        for index in chats.indices {
            let chat = chats[index]
            guard chat.envelope.binding.kind == .deepseek, chat.envelope.binding.profileID == "deepseek-default",
                  chat.envelope.binding.origin == DeepSeekContract.origin,
                  let selection = chat.envelope.selection, selection.providerID == "deepseek",
                  DeepSeekContract.models.contains(selection.modelID), chat.envelope.remoteSession == nil,
                  chat.envelope.messages.allSatisfy({ $0.role == .user || $0.role == .assistant }),
                  chat.envelope.messages.allSatisfy({ $0.toolCalls.isEmpty && $0.documents.isEmpty }),
                  chat.pendingUser == nil || chat.pendingUser?.role == .user,
                  chat.partialAssistant == nil || chat.partialAssistant?.role == .assistant else { throw DeepSeekFailure.persistence }
            _ = try NativeConversationCodec().encodeEnvelope(chat.envelope)
            if chat.state == .running {
                chats[index].state = .interrupted
                chats[index].failure = DeepSeekFailureRecord(.interrupted)
            }
            if chat.state == .ready, chat.pendingUser != nil || chat.partialAssistant != nil { throw DeepSeekFailure.persistence }
        }
        if let selectedChatID, !chats.contains(where: { $0.id == selectedChatID }) { throw DeepSeekFailure.persistence }
    }
}

public protocol DeepSeekJournalStorage: Sendable {
    func load() throws -> DeepSeekJournal?
    /// Atomically commit the journal, or throw while preserving the previous journal.
    func save(_ journal: DeepSeekJournal) throws
}

public struct DeepSeekFileJournalStorage: DeepSeekJournalStorage {
    private let file: URL?
    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.appendingPathComponent("deepseek", isDirectory: true)
        file = base?.appendingPathComponent("history-v1.json")
    }
    public func load() throws -> DeepSeekJournal? {
        guard let file else { throw DeepSeekFailure.persistence }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= DeepSeekContract.maxBytes else { throw DeepSeekFailure.persistence }
            let data = try Data(contentsOf: file)
            try NativeStrictJSON.validate(data)
            var journal = try JSONDecoder().decode(DeepSeekJournal.self, from: data)
            try journal.validateAndRecover()
            return journal
        } catch { throw DeepSeekFailure.persistence }
    }
    public func save(_ journal: DeepSeekJournal) throws {
        guard let file else { throw DeepSeekFailure.persistence }
        do {
            var validated = journal; try validated.validateAndRecover()
            // Keep a running receipt on disk; recovery only happens while loading.
            let data = try JSONEncoder().encode(journal)
            guard data.count <= DeepSeekContract.maxBytes else { throw DeepSeekFailure.persistence }
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let staged = directory.appendingPathComponent(".history-" + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            #if os(iOS)
            try data.write(to: staged, options: [.atomic, .completeUntilFirstUserAuthentication])
            #else
            try data.write(to: staged, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            // rename(2) is the final atomic commit. All fallible metadata work precedes
            // it, so a thrown save never means "committed, but reported as failed".
            guard rename(staged.path, file.path) == 0 else { throw DeepSeekFailure.persistence }
        } catch { throw DeepSeekFailure.persistence }
    }
}
