import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum NativeConnectionKind: String, Sendable, NativeWireEnum {
    case local, deepseek, remoteHarness
}

/// An HTTPS origin, never a URL with credentials, a path, query, or fragment.
enum NativeConnectionOrigin {
    static func canonical(_ value: String) throws -> String {
        guard value.utf8.count <= 2_048, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              value.lowercased().hasPrefix("https://") else { throw NativeConnectionError.invalidValue }
        var authority = String(value.dropFirst(8))
        if authority.hasSuffix("/") { authority.removeLast() }
        guard !authority.isEmpty, !authority.contains(where: { "/?#@\\%".contains($0) }) else {
            throw NativeConnectionError.invalidValue
        }
        let host: String
        let portText: String?
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { throw NativeConnectionError.invalidValue }
            let address = String(authority[authority.index(after: authority.startIndex)..<closing])
            guard validIPv6(address) else { throw NativeConnectionError.invalidValue }
            host = "[" + address.lowercased() + "]"
            let suffix = authority[authority.index(after: closing)...]
            if suffix.isEmpty { portText = nil }
            else {
                guard suffix.hasPrefix(":") else { throw NativeConnectionError.invalidValue }
                portText = String(suffix.dropFirst())
            }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw NativeConnectionError.invalidValue }
            host = String(parts[0]).lowercased()
            guard host.utf8.count <= 253, !host.isEmpty,
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                  }) else { throw NativeConnectionError.invalidValue }
            if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }), !validIPv4(host) {
                throw NativeConnectionError.invalidValue
            }
            portText = parts.count == 2 ? String(parts[1]) : nil
        }
        if let portText {
            guard !portText.isEmpty, portText.count <= 5, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(portText), (1...65_535).contains(port) else { throw NativeConnectionError.invalidValue }
            return "https://" + host + (port == 443 ? "" : ":\(port)")
        }
        return "https://" + host
    }

    private static func validIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && $0.count <= 3 && ($0.count == 1 || $0.first != "0")
            && $0.utf8.allSatisfy({ (48...57).contains($0) }) && Int($0).map { (0...255).contains($0) } == true
        }
    }

    private static func validIPv6(_ address: String) -> Bool {
        // inet_pton parses numeric addresses without DNS resolution and handles
        // compressed/embedded forms using the platform's maintained parser.
        guard !address.isEmpty, address.utf8.count <= 45, address.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46
        }) else { return false }
        // Darwin accepts some dotted suffixes with leading zeros. Keep our
        // stricter cross-platform IPv4 spelling before the platform IPv6 parse.
        if address.contains(".") {
            guard let suffix = address.split(separator: ":", omittingEmptySubsequences: false).last,
                  validIPv4(String(suffix)) else { return false }
        }
        #if canImport(Darwin) || canImport(Glibc)
        var parsed = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &parsed) } == 1
        #else
        return false
        #endif
    }
}

/// Stores an opaque credential LABEL only. Credential values have no field in this format.
public struct NativeConnectionProfile: Sendable, Equatable, NativeWireObject {
    public let id: String
    public let kind: NativeConnectionKind
    public let displayName: String
    public let endpoint: String?
    public let credentialReference: String?
    public let hostID: String?
    public let hostFingerprint: String?
    public let workspaceID: String?

    public init(id: String, kind: NativeConnectionKind, displayName: String, endpoint: String? = nil,
                credentialReference: String? = nil, hostID: String? = nil, hostFingerprint: String? = nil,
                workspaceID: String? = nil) throws {
        try NativeConnectionBounds.identifier(id)
        try NativeConnectionBounds.text(displayName)
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeConnectionError.invalidValue }
        if let credentialReference {
            guard credentialReference.hasPrefix("qcred:") else { throw NativeConnectionError.invalidValue }
            try NativeConnectionBounds.identifier(String(credentialReference.dropFirst(6)))
        }
        let origin = try endpoint.map(NativeConnectionOrigin.canonical)
        try NativeConversationBinding.validateDestination(kind: kind, origin: origin, hostID: hostID,
                                                         hostFingerprint: hostFingerprint, workspaceID: workspaceID)
        guard kind != .local || credentialReference == nil else { throw NativeConnectionError.invalidValue }
        self.id = id; self.kind = kind; self.displayName = displayName; self.endpoint = origin
        self.credentialReference = credentialReference; self.hostID = hostID
        self.hostFingerprint = hostFingerprint; self.workspaceID = workspaceID
    }

    public var binding: NativeConversationBinding {
        // The profile constructor and decoder validate these identical fields.
        NativeConversationBinding(validatedProfile: self)
    }
    static let wireKeys: Set<String> = ["id", "kind", "displayName", "endpoint", "credentialReference", "hostID", "hostFingerprint", "workspaceID"]
    init(fields: NativeFields) throws {
        try self.init(id: fields.required("id"), kind: fields.required("kind"), displayName: fields.required("displayName"),
                      endpoint: fields.optional("endpoint"), credentialReference: fields.optional("credentialReference"),
                      hostID: fields.optional("hostID"), hostFingerprint: fields.optional("hostFingerprint"), workspaceID: fields.optional("workspaceID"))
    }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("id", id); try values.put("kind", kind); try values.put("displayName", displayName)
        try values.putOptional("endpoint", endpoint); try values.putOptional("credentialReference", credentialReference)
        try values.putOptional("hostID", hostID); try values.putOptional("hostFingerprint", hostFingerprint); try values.putOptional("workspaceID", workspaceID)
    }
}

public struct NativeConversationBinding: Sendable, Equatable, NativeWireObject {
    public let profileID: String
    public let kind: NativeConnectionKind
    public let origin: String?
    public let hostID: String?
    public let hostFingerprint: String?
    public let workspaceID: String?

    public init(profileID: String, kind: NativeConnectionKind, origin: String? = nil, hostID: String? = nil,
                hostFingerprint: String? = nil, workspaceID: String? = nil) throws {
        try NativeConnectionBounds.identifier(profileID)
        let canonicalOrigin = try origin.map(NativeConnectionOrigin.canonical)
        try Self.validateDestination(kind: kind, origin: canonicalOrigin, hostID: hostID,
                                     hostFingerprint: hostFingerprint, workspaceID: workspaceID)
        self.profileID = profileID; self.kind = kind; self.origin = canonicalOrigin
        self.hostID = hostID; self.hostFingerprint = hostFingerprint; self.workspaceID = workspaceID
    }
    fileprivate init(validatedProfile profile: NativeConnectionProfile) {
        profileID = profile.id; kind = profile.kind; origin = profile.endpoint
        hostID = profile.hostID; hostFingerprint = profile.hostFingerprint; workspaceID = profile.workspaceID
    }
    static func validateDestination(kind: NativeConnectionKind, origin: String?, hostID: String?, hostFingerprint: String?, workspaceID: String?) throws {
        switch kind {
        case .local:
            guard origin == nil, hostID == nil, hostFingerprint == nil, workspaceID == nil else { throw NativeConnectionError.invalidValue }
        case .deepseek:
            guard origin == "https://api.deepseek.com", hostID == nil, hostFingerprint == nil, workspaceID == nil
            else { throw NativeConnectionError.invalidValue }
        case .remoteHarness:
            guard origin != nil, let hostID, let hostFingerprint, let workspaceID else { throw NativeConnectionError.invalidValue }
            try NativeConnectionBounds.identifier(hostID); try NativeConnectionBounds.identifier(workspaceID)
            try NativeConnectionBounds.digest(hostFingerprint)
        }
    }
    /// No fallback, rebinding, or inference from a display name. A changed destination needs
    /// a separately created conversation and an explicit transfer outside this foundation.
    public func requireMatch(_ profile: NativeConnectionProfile) throws {
        guard self == profile.binding else { throw NativeConnectionError.dispatchMismatch }
    }
    static let wireKeys: Set<String> = ["profileID", "kind", "origin", "hostID", "hostFingerprint", "workspaceID"]
    init(fields: NativeFields) throws {
        try self.init(profileID: fields.required("profileID"), kind: fields.required("kind"), origin: fields.optional("origin"),
                      hostID: fields.optional("hostID"), hostFingerprint: fields.optional("hostFingerprint"), workspaceID: fields.optional("workspaceID"))
    }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("profileID", profileID); try values.put("kind", kind); try values.putOptional("origin", origin)
        try values.putOptional("hostID", hostID); try values.putOptional("hostFingerprint", hostFingerprint); try values.putOptional("workspaceID", workspaceID)
    }
}

public enum ProviderReasoningEffort: String, Sendable, NativeWireEnum { case off, low, high, max }
public struct ProviderSelection: Sendable, Equatable, NativeWireObject {
    public let providerID: String
    public let modelID: String
    public let reasoningEffort: ProviderReasoningEffort
    public init(providerID: String, modelID: String, reasoningEffort: ProviderReasoningEffort) throws {
        try NativeConnectionBounds.identifier(providerID); try NativeConnectionBounds.identifier(modelID)
        self.providerID = providerID; self.modelID = modelID; self.reasoningEffort = reasoningEffort
    }
    static let wireKeys: Set<String> = ["providerID", "modelID", "reasoningEffort"]
    init(fields: NativeFields) throws { try self.init(providerID: fields.required("providerID"), modelID: fields.required("modelID"), reasoningEffort: fields.required("reasoningEffort")) }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("providerID", providerID); try values.put("modelID", modelID); try values.put("reasoningEffort", reasoningEffort)
    }
}

public struct ProviderDocument: Sendable, Equatable, NativeWireObject {
    public let name: String
    public let text: String
    public init(name: String, text: String) throws {
        try NativeConnectionBounds.text(name); try NativeConnectionBounds.text(text)
        self.name = name; self.text = text
    }
    static let wireKeys: Set<String> = ["name", "text"]
    init(fields: NativeFields) throws { try self.init(name: fields.required("name"), text: fields.required("text")) }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws { try values.put("name", name); try values.put("text", text) }
}

public struct ProviderToolCall: Sendable, Equatable, NativeWireObject {
    public let id: String
    public let name: String
    /// Original provider argument bytes represented as a String; never parsed or executed here.
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) throws {
        try NativeConnectionBounds.identifier(id); try NativeConnectionBounds.identifier(name); try NativeConnectionBounds.text(argumentsJSON)
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
    static let wireKeys: Set<String> = ["id", "name", "argumentsJSON"]
    init(fields: NativeFields) throws { try self.init(id: fields.required("id"), name: fields.required("name"), argumentsJSON: fields.required("argumentsJSON")) }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("id", id); try values.put("name", name); try values.put("argumentsJSON", argumentsJSON)
    }
}

public enum ProviderMessageRole: String, Sendable, NativeWireEnum { case system, user, assistant, tool }
public struct ProviderMessage: Sendable, Equatable, NativeWireObject {
    public let id: String
    public let role: ProviderMessageRole
    public let content: String
    public let reasoningContent: String?
    public let toolCalls: [ProviderToolCall]
    public let toolCallID: String?
    public let documents: [ProviderDocument]

    public init(id: String, role: ProviderMessageRole, content: String, reasoningContent: String? = nil,
                toolCalls: [ProviderToolCall] = [], toolCallID: String? = nil, documents: [ProviderDocument] = []) throws {
        try NativeConnectionBounds.identifier(id); try NativeConnectionBounds.text(content)
        if let reasoningContent { try NativeConnectionBounds.text(reasoningContent) }
        guard toolCalls.count <= NativeConnectionBounds.toolCalls, documents.count <= NativeConnectionBounds.documents
        else { throw NativeConnectionError.limitExceeded }
        try NativeConnectionBounds.unique(toolCalls.map(\.id))
        guard role == .assistant || (reasoningContent == nil && toolCalls.isEmpty),
              role == .user || documents.isEmpty else { throw NativeConnectionError.invalidValue }
        if role == .tool {
            guard let toolCallID else { throw NativeConnectionError.invalidValue }
            try NativeConnectionBounds.identifier(toolCallID)
        } else if toolCallID != nil { throw NativeConnectionError.invalidValue }
        self.id = id; self.role = role; self.content = content; self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.documents = documents
    }
    static let wireKeys: Set<String> = ["id", "role", "content", "reasoningContent", "toolCalls", "toolCallID", "documents"]
    init(fields: NativeFields) throws {
        let role: ProviderMessageRole = try fields.required("role")
        guard role == .assistant || (!fields.values.contains(NativeKey("reasoningContent")) && !fields.values.contains(NativeKey("toolCalls"))),
              role == .user || !fields.values.contains(NativeKey("documents")) else { throw NativeConnectionError.invalidValue }
        try self.init(id: fields.required("id"), role: role, content: fields.required("content"),
                      reasoningContent: fields.optional("reasoningContent"), toolCalls: fields.array("toolCalls"),
                      toolCallID: fields.optional("toolCallID"), documents: fields.array("documents"))
    }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("id", id); try values.put("role", role); try values.put("content", content)
        try values.putOptional("reasoningContent", reasoningContent); try values.putArray("toolCalls", toolCalls)
        try values.putOptional("toolCallID", toolCallID); try values.putArray("documents", documents)
    }
}

public struct NativeConversationEnvelope: Sendable, Equatable, NativeWireObject {
    public let schemaVersion: Int
    public let conversationID: String
    public let binding: NativeConversationBinding
    public let selection: ProviderSelection?
    public let messages: [ProviderMessage]
    public let remoteSession: RemoteSessionState?

    public init(schemaVersion: Int = 1, conversationID: String, binding: NativeConversationBinding,
                selection: ProviderSelection? = nil, messages: [ProviderMessage], remoteSession: RemoteSessionState? = nil) throws {
        guard schemaVersion == 1 else { throw NativeConnectionError.unsupportedVersion }
        try NativeConnectionBounds.identifier(conversationID)
        guard messages.count <= NativeConnectionBounds.messages else { throw NativeConnectionError.limitExceeded }
        try NativeConnectionBounds.unique(messages.map(\.id))
        if let remoteSession {
            guard binding.kind == .remoteHarness, binding.hostID == remoteSession.hostID,
                  binding.workspaceID == remoteSession.workspaceID else { throw NativeConnectionError.sessionMismatch }
        }
        var size = NativeWireSizeBudget()
        for text in [conversationID, binding.profileID, binding.origin, binding.hostID, binding.hostFingerprint, binding.workspaceID,
                     selection?.providerID, selection?.modelID] { try size.include(text) }
        for message in messages {
            for text in [message.id, message.content, message.reasoningContent, message.toolCallID] { try size.include(text) }
            for call in message.toolCalls {
                for text in [call.id, call.name, call.argumentsJSON] { try size.include(text) }
            }
            for document in message.documents { try size.include(document.name); try size.include(document.text) }
        }
        if let remoteSession {
            for text in [remoteSession.hostID, remoteSession.deviceID, remoteSession.workspaceID, remoteSession.sessionID,
                         remoteSession.runID, remoteSession.lastConfirmedEventID] { try size.include(text) }
            for command in remoteSession.pendingCommands { try size.include(command.requestID) }
            for approval in remoteSession.pendingApprovals {
                for text in [approval.approvalID, approval.requestID, approval.hostID, approval.deviceID, approval.workspaceID,
                             approval.sessionID, approval.runID, approval.actionDigest] { try size.include(text) }
            }
        }
        self.schemaVersion = schemaVersion; self.conversationID = conversationID; self.binding = binding
        self.selection = selection; self.messages = messages; self.remoteSession = remoteSession
    }
    public func requireDispatch(to profile: NativeConnectionProfile) throws { try binding.requireMatch(profile) }
    static let wireKeys: Set<String> = ["schemaVersion", "conversationID", "binding", "selection", "messages", "remoteSession"]
    init(fields: NativeFields) throws {
        try self.init(schemaVersion: fields.required("schemaVersion"), conversationID: fields.required("conversationID"),
                      binding: fields.required("binding"), selection: fields.optional("selection"), messages: fields.required("messages"),
                      remoteSession: fields.optional("remoteSession"))
    }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("schemaVersion", schemaVersion); try values.put("conversationID", conversationID); try values.put("binding", binding)
        try values.putOptional("selection", selection); try values.put("messages", messages); try values.putOptional("remoteSession", remoteSession)
    }
}

/// Use these methods at raw-data boundaries. JSONDecoder alone cannot detect duplicate keys.
/// The codec is in-memory and never writes over a legacy file or activates a destination.
public struct NativeConversationCodec: Sendable {
    public init() {}
    public func decodeProfile(_ data: Data) throws -> NativeConnectionProfile { try decode(NativeConnectionProfile.self, data) }
    public func encodeProfile(_ profile: NativeConnectionProfile) throws -> Data { try encode(profile) }
    public func decodeEnvelope(_ data: Data) throws -> NativeConversationEnvelope { try decode(NativeConversationEnvelope.self, data) }
    public func encodeEnvelope(_ envelope: NativeConversationEnvelope) throws -> Data { try encode(envelope) }

    /// Arrays are the ONLY legacy shape. Objects, including unknown versioned formats,
    /// are decoded as envelopes and never retried as legacy after a validation failure.
    public func decodeOrMigrate(_ data: Data, conversationID: String) throws -> NativeConversationEnvelope {
        if !data.isEmpty {
            try NativeStrictJSON.validate(data)
            if data.first(where: { ![9, 10, 13, 32].contains($0) }) != 91 { return try decodeEnvelope(data) }
        }
        let legacy: [ChatMessage]
        do { legacy = try ConversationStore().decode(data) }
        catch { throw NativeConnectionError.invalidValue }
        guard legacy.count <= NativeConnectionBounds.messages else { throw NativeConnectionError.limitExceeded }
        let messages = try legacy.enumerated().map { index, message in
            try ProviderMessage(id: "legacy-\(index)", role: message.role == .user ? .user : .assistant, content: message.text,
                                documents: message.documents.map { try ProviderDocument(name: $0.name, text: $0.text) })
        }
        let binding = try NativeConversationBinding(profileID: "local-default", kind: .local)
        return try NativeConversationEnvelope(conversationID: conversationID, binding: binding, messages: messages)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try NativeStrictJSON.validate(data)
        do { return try JSONDecoder().decode(type, from: data) }
        catch let error as NativeConnectionError { throw error }
        catch { throw NativeConnectionError.invalidValue }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let data: Data
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; data = try encoder.encode(value) }
        catch { throw NativeConnectionError.invalidValue }
        try NativeStrictJSON.validate(data)
        return data
    }
}
