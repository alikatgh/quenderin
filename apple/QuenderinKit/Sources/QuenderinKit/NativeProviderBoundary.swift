import Foundation

/// Advertised behavior is data. This foundation supplies no active provider or transport.
public struct ProviderCapabilities: Sendable, Equatable {
    public let reasoning: Bool
    public let toolCalls: Bool
    public let documents: Bool
    public let cancellation: Bool
    public let usage: Bool
    public init(reasoning: Bool, toolCalls: Bool, documents: Bool, cancellation: Bool, usage: Bool) {
        self.reasoning = reasoning; self.toolCalls = toolCalls; self.documents = documents
        self.cancellation = cancellation; self.usage = usage
    }
}

public struct ProviderToolDefinition: Sendable, Equatable, NativeWireObject, NativeConnectionPrivateValue {
    public let name: String
    public let toolDescription: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) throws {
        try NativeConnectionBounds.identifier(name); try NativeConnectionBounds.text(description)
        try NativeConnectionBounds.text(parametersJSON)
        try NativeStrictJSON.validate(Data(parametersJSON.utf8), integerNumbersOnly: false)
        guard parametersJSON.utf8.first(where: { ![9, 10, 13, 32].contains($0) }) == 123
        else { throw NativeConnectionError.invalidValue }
        self.name = name; self.toolDescription = description; self.parametersJSON = parametersJSON
    }
    static let wireKeys: Set<String> = ["name", "description", "parametersJSON"]
    init(fields: NativeFields) throws { try self.init(name: fields.required("name"), description: fields.required("description"), parametersJSON: fields.required("parametersJSON")) }
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws {
        try values.put("name", name); try values.put("description", toolDescription); try values.put("parametersJSON", parametersJSON)
    }
}

public struct ProviderRequestLimits: Sendable, Equatable {
    public let maxOutputTokens: Int64
    public let maxToolCalls: Int
    public let deadlineEpochMs: Int64
    public init(maxOutputTokens: Int64, maxToolCalls: Int, deadlineEpochMs: Int64) throws {
        try NativeConnectionBounds.counter(maxOutputTokens, positive: true)
        try NativeConnectionBounds.counter(deadlineEpochMs, positive: true)
        guard (0...NativeConnectionBounds.toolCalls).contains(maxToolCalls) else { throw NativeConnectionError.limitExceeded }
        self.maxOutputTokens = maxOutputTokens; self.maxToolCalls = maxToolCalls; self.deadlineEpochMs = deadlineEpochMs
    }
}

/// Complete structured history crosses this boundary: no display transcript flattening,
/// reasoning removal, synthetic tool results, implicit destination change, or credential value.
public struct ProviderRequest: Sendable, Equatable, NativeConnectionPrivateValue {
    public let requestID: String
    public let envelope: NativeConversationEnvelope
    public var conversationID: String { envelope.conversationID }
    public var binding: NativeConversationBinding { envelope.binding }
    public var messages: [ProviderMessage] { envelope.messages }
    public let capabilities: ProviderCapabilities
    public let tools: [ProviderToolDefinition]
    public let selection: ProviderSelection
    public let limits: ProviderRequestLimits

    public init(requestID: String, profile: NativeConnectionProfile, envelope: NativeConversationEnvelope,
                capabilities: ProviderCapabilities, tools: [ProviderToolDefinition], limits: ProviderRequestLimits,
                nowEpochMs: Int64) throws {
        try NativeConnectionBounds.identifier(requestID)
        try envelope.requireDispatch(to: profile)
        try NativeConnectionBounds.counter(nowEpochMs)
        guard let selection = envelope.selection else { throw NativeConnectionError.invalidValue }
        guard nowEpochMs < limits.deadlineEpochMs else { throw NativeConnectionError.invalidValue }
        guard tools.count <= NativeConnectionBounds.toolCalls else { throw NativeConnectionError.limitExceeded }
        try NativeConnectionBounds.unique(tools.map(\.name))
        guard capabilities.toolCalls || (tools.isEmpty && !envelope.messages.contains { !$0.toolCalls.isEmpty || $0.role == .tool }),
              capabilities.reasoning || (selection.reasoningEffort == .off && !envelope.messages.contains { $0.reasoningContent != nil }),
              capabilities.documents || !envelope.messages.contains(where: { !$0.documents.isEmpty })
        else { throw NativeConnectionError.invalidValue }
        // Check the complete encoded envelope as well as individual message limits. This
        // prevents programmatically constructed requests bypassing aggregate persistence bounds.
        let encodedEnvelope = try NativeConversationCodec().encodeEnvelope(envelope)
        var budget = NativeWireSizeBudget()
        try budget.include(String(decoding: encodedEnvelope, as: UTF8.self))
        for tool in tools {
            try budget.include(tool.name); try budget.include(tool.toolDescription); try budget.include(tool.parametersJSON)
        }
        self.requestID = requestID; self.envelope = envelope
        self.capabilities = capabilities; self.tools = tools; self.selection = selection; self.limits = limits
    }
}

public enum ProviderCompletionReason: String, Sendable, Equatable, NativeWireEnum { case end, toolCalls, outputLimit }
public enum ProviderFailureCode: String, Sendable, Equatable, NativeWireEnum {
    case unavailable, unauthorized, rateLimited, deadlineExceeded, invalidResponse, connectionLost, rejected, limitExceeded, outcomeUnknown
}

public struct ProviderTextDelta: Sendable, Equatable, NativeConnectionPrivateValue {
    public let messageID: String
    public let delta: String
    public init(messageID: String, delta: String) throws {
        try NativeConnectionBounds.identifier(messageID); try NativeConnectionBounds.text(delta)
        self.messageID = messageID; self.delta = delta
    }
}

public struct ProviderToolCallFragment: Sendable, Equatable, NativeConnectionPrivateValue {
    public let messageID: String
    public let callID: String?
    public let name: String?
    public let index: Int
    public let argumentsDelta: String
    public init(messageID: String, callID: String? = nil, name: String? = nil, index: Int, argumentsDelta: String) throws {
        try NativeConnectionBounds.identifier(messageID)
        if let callID { try NativeConnectionBounds.identifier(callID) }
        if let name { try NativeConnectionBounds.identifier(name) }
        guard (0..<NativeConnectionBounds.toolCalls).contains(index) else { throw NativeConnectionError.limitExceeded }
        try NativeConnectionBounds.text(argumentsDelta)
        self.messageID = messageID; self.callID = callID; self.name = name; self.index = index; self.argumentsDelta = argumentsDelta
    }
}

public struct ProviderUsage: Sendable, Equatable, NativeConnectionPrivateValue {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public init(inputTokens: Int64, outputTokens: Int64) throws {
        try NativeConnectionBounds.counter(inputTokens); try NativeConnectionBounds.counter(outputTokens)
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

/// Future adapters must deliberately map streaming events into these distinct cases. A
/// failure code contains no raw remote diagnostics. A cancelled stream is not a stop receipt
/// from a remote Host, and transport failure does not establish an action's final outcome.
public enum ProviderEvent: Sendable, Equatable, NativeConnectionPrivateValue {
    case text(ProviderTextDelta)
    case reasoning(ProviderTextDelta)
    case toolCallFragment(ProviderToolCallFragment)
    case usage(ProviderUsage)
    case completion(ProviderCompletionReason)
    case cancellation
    case failure(ProviderFailureCode)
}
