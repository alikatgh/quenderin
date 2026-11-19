import Foundation

/// Fixed Quenderin extension, carried by plugin.route.call. This is deliberately
/// not a generic plugin proxy or one of the Harness session Gateway endpoints.
enum RemoteHarnessBotReadContract {
    static let capability = "quenderin.bot.read.v1"
    static let carrierCapability = "plugin.route.v1"
    static let requestBytes = 4_096
    static let resultBytes = 262_144
    static let bots = 100

    static func text(_ value: RemoteHarnessJSON, maximum: Int) throws -> String {
        let text = try value.stringValue()
        guard !text.isEmpty, !text.utf8.contains(0), text.utf8.count <= maximum else {
            throw RemoteHarnessError.invalidMessage
        }
        return text
    }
    static func optionalText(_ value: RemoteHarnessJSON, maximum: Int) throws -> String? {
        if value.data == Data("null".utf8) { return nil }
        return try text(value, maximum: maximum)
    }
    static func workspace(_ value: String) throws {
        guard !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 1_024 else {
            throw RemoteHarnessError.bindingMismatch
        }
    }
    static func requestWorkspace(_ params: RemoteHarnessJSON) throws -> String {
        guard params.data.count <= requestBytes else { throw RemoteHarnessError.limitExceeded }
        let fields = try params.fields(); try fields.requireKeys(["route", "body"])
        guard try fields.required("route").stringValue().utf8.elementsEqual("api/bot".utf8) else {
            throw RemoteHarnessError.endpointNotAllowed
        }
        let body = try fields.required("body").fields(); try body.requireKeys(["endpoint", "payload"])
        guard try body.required("endpoint").stringValue().utf8.elementsEqual("quenderin-roster".utf8) else {
            throw RemoteHarnessError.endpointNotAllowed
        }
        let payload = try body.required("payload").fields(); try payload.requireKeys(["schemaVersion", "workspaceId"])
        guard try payload.required("schemaVersion").integerValue() == 1 else { throw RemoteHarnessError.unsupportedVersion }
        return try text(payload.required("workspaceId"), maximum: 1_024)
    }
}

/// Display metadata only. Neither the IDs nor permission text authorizes a
/// session call, tool execution, or approval. Explicit properties are private exports.
public struct RemoteHarnessBot: Sendable, Equatable, NativeConnectionPrivateValue {
    public let id: String
    public let name: String
    public let sessionID: String
    public let model: String?
    public let permission: String?

    init(_ value: RemoteHarnessJSON) throws {
        let fields = try value.fields(); try fields.requireKeys(["id", "name", "sessionId", "model", "permission"])
        id = try RemoteHarnessBotReadContract.text(fields.required("id"), maximum: 1_024)
        name = try RemoteHarnessBotReadContract.text(fields.required("name"), maximum: 256)
        sessionID = try RemoteHarnessBotReadContract.text(fields.required("sessionId"), maximum: 1_024)
        model = try RemoteHarnessBotReadContract.optionalText(fields.required("model"), maximum: 256)
        permission = try RemoteHarnessBotReadContract.optionalText(fields.required("permission"), maximum: 64)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.sessionID.utf8.elementsEqual(rhs.sessionID.utf8)
            && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.model.map { Data($0.utf8) } == rhs.model.map { Data($0.utf8) }
            && lhs.permission.map { Data($0.utf8) } == rhs.permission.map { Data($0.utf8) }
    }
}

/// Validates the raw plugin route {status,json} result, never a Gateway unwrap.
/// Host and connection provenance stay in the authenticated coordinator binding.
public struct RemoteHarnessBotRoster: Sendable, Equatable, NativeConnectionPrivateValue {
    public let schemaVersion: Int64
    public let workspaceID: String
    public let revision: Int64
    public let readOnly: Bool
    public let bots: [RemoteHarnessBot]

    public init(data: Data, expectedWorkspaceID: String) throws {
        guard data.count <= RemoteHarnessBotReadContract.resultBytes else { throw RemoteHarnessError.limitExceeded }
        try self.init(routeResult: RemoteHarnessJSON(data: data), expectedWorkspaceID: expectedWorkspaceID)
    }
    public init(routeResult: RemoteHarnessJSON, expectedWorkspaceID: String) throws {
        try RemoteHarnessBotReadContract.workspace(expectedWorkspaceID)
        guard routeResult.data.count <= RemoteHarnessBotReadContract.resultBytes else { throw RemoteHarnessError.limitExceeded }
        let fields = try routeResult.fields(); try fields.requireKeys(["status", "json"])
        // Non-success errors remain fixed diagnostics; private Host error bodies
        // are never decoded into an error message or passed to a completion.
        guard try fields.required("status").integerValue() == 200 else { throw RemoteHarnessError.invalidMessage }
        let json = try fields.required("json").fields(); try json.requireKeys(["ok", "value"])
        guard try json.required("ok").booleanValue() else { throw RemoteHarnessError.invalidMessage }
        let value = try json.required("value").fields()
        try value.requireKeys(["schemaVersion", "workspaceId", "revision", "readOnly", "bots"])
        schemaVersion = try value.required("schemaVersion").integerValue()
        guard schemaVersion == 1 else { throw RemoteHarnessError.unsupportedVersion }
        workspaceID = try RemoteHarnessBotReadContract.text(value.required("workspaceId"), maximum: 1_024)
        guard workspaceID.utf8.elementsEqual(expectedWorkspaceID.utf8) else { throw RemoteHarnessError.bindingMismatch }
        revision = try value.required("revision").integerValue()
        readOnly = try value.required("readOnly").booleanValue()
        let items = try value.required("bots").elements()
        guard items.count <= RemoteHarnessBotReadContract.bots else { throw RemoteHarnessError.limitExceeded }
        bots = try items.map(RemoteHarnessBot.init)
        var ids = Set<Data>(), sessions = Set<Data>()
        for bot in bots {
            guard ids.insert(Data(bot.id.utf8)).inserted, sessions.insert(Data(bot.sessionID.utf8)).inserted else {
                throw RemoteHarnessError.invalidMessage
            }
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.workspaceID.utf8.elementsEqual(rhs.workspaceID.utf8)
            && lhs.revision == rhs.revision && lhs.readOnly == rhs.readOnly && lhs.bots == rhs.bots
    }
}

/// Persistent Bot work is a separate, fixed extension. It never uses a raw
/// session prompt, creates a Bot, or treats admission as turn completion.
enum RemoteHarnessBotWorkContract {
    static let capability = "quenderin.bot.work.v1"
    static let requestBytes = 32_768
    static let resultBytes = 8_192
    static let textBytes = 16_384
    static func request(_ params: RemoteHarnessJSON) throws -> (endpoint: String, workspace: String, bot: String, command: String, session: String?) {
        guard params.data.count <= requestBytes else { throw RemoteHarnessError.limitExceeded }
        let fields = try params.fields(); try fields.requireKeys(["route", "body"])
        guard try fields.required("route").stringValue().utf8.elementsEqual("api/bot".utf8) else { throw RemoteHarnessError.endpointNotAllowed }
        let body = try fields.required("body").fields(); try body.requireKeys(["endpoint", "payload"])
        let endpoint = try body.text("endpoint")
        guard ["quenderin-submit", "quenderin-command"].contains(endpoint) else { throw RemoteHarnessError.endpointNotAllowed }
        let payload = try body.required("payload").fields()
        try payload.requireKeys(endpoint == "quenderin-submit"
            ? ["schemaVersion", "workspaceId", "botId", "expectedSessionId", "expectedRevision", "commandId", "text"]
            : ["schemaVersion", "workspaceId", "botId", "commandId"])
        guard try payload.required("schemaVersion").integerValue() == 1 else { throw RemoteHarnessError.unsupportedVersion }
        let workspace = try RemoteHarnessBotReadContract.text(payload.required("workspaceId"), maximum: 1_024)
        let bot = try RemoteHarnessBotReadContract.text(payload.required("botId"), maximum: 1_024)
        let command = try RemoteHarnessBotReadContract.text(payload.required("commandId"), maximum: 128)
        var session: String?
        if endpoint == "quenderin-submit" {
            session = try RemoteHarnessBotReadContract.text(payload.required("expectedSessionId"), maximum: 1_024)
            _ = try payload.required("expectedRevision").integerValue()
            let text = try RemoteHarnessBotReadContract.text(payload.required("text"), maximum: textBytes)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteHarnessError.invalidMessage }
        }
        return (endpoint, workspace, bot, command, session)
    }
}

public enum RemoteHarnessBotCommandState: String, Sendable { case accepted, rejected, uncertain, notFound }
public enum RemoteHarnessBotCommandReason: String, Sendable {
    case staleSession, staleRevision, unavailable, readOnly, revoked, wrongScope, payloadConflict, capacity, storageFailure, dispatchUncertain, invalidRequest
    public var explanation: String {
        switch self {
        case .staleSession, .staleRevision: return "The Bot changed. Refresh its conversation before sending new work."
        case .unavailable: return "The Bot is currently unavailable on your computer."
        case .readOnly: return "This computer currently permits viewing only."
        case .revoked, .wrongScope: return "This connection no longer has permission to work with this Bot."
        case .payloadConflict: return "The saved command identity already belongs to different work. Its original receipt is preserved."
        case .capacity: return "The Bot already has unsettled work, or the computer has reached its work limit."
        case .storageFailure: return "The computer could not safely save this command."
        case .dispatchUncertain: return "The computer cannot yet confirm whether this command entered the Bot queue."
        case .invalidRequest: return "The computer refused this command. Refresh before preparing new work."
        }
    }
}
public struct RemoteHarnessBotCommandReceipt: Sendable, Equatable, NativeConnectionPrivateValue {
    public let workspaceID: String
    public let botID: String
    public let commandID: String
    public let sessionID: String?
    public let revision: Int64?
    public let state: RemoteHarnessBotCommandState
    public let reason: RemoteHarnessBotCommandReason?
    public init(routeResult: RemoteHarnessJSON, expectedWorkspaceID: String, expectedBotID: String, expectedCommandID: String) throws {
        guard routeResult.data.count <= RemoteHarnessBotWorkContract.resultBytes else { throw RemoteHarnessError.limitExceeded }
        let outer = try routeResult.fields(); try outer.requireKeys(["status", "json"])
        guard try outer.required("status").integerValue() == 200 else { throw RemoteHarnessError.invalidMessage }
        let json = try outer.required("json").fields(); try json.requireKeys(["ok", "value"])
        guard try json.required("ok").booleanValue() else { throw RemoteHarnessError.invalidMessage }
        let value = try json.required("value").fields()
        try value.requireKeys(["schemaVersion", "workspaceId", "botId", "commandId", "sessionId", "revision", "state", "reason"])
        guard try value.required("schemaVersion").integerValue() == 1 else { throw RemoteHarnessError.unsupportedVersion }
        workspaceID = try RemoteHarnessBotReadContract.text(value.required("workspaceId"), maximum: 1_024)
        botID = try RemoteHarnessBotReadContract.text(value.required("botId"), maximum: 1_024)
        commandID = try RemoteHarnessBotReadContract.text(value.required("commandId"), maximum: 128)
        guard zip([workspaceID, botID, commandID], [expectedWorkspaceID, expectedBotID, expectedCommandID]).allSatisfy({ $0.0.utf8.elementsEqual($0.1.utf8) }) else { throw RemoteHarnessError.bindingMismatch }
        sessionID = try RemoteHarnessBotReadContract.optionalText(value.required("sessionId"), maximum: 1_024)
        let rawRevision = try value.required("revision")
        if rawRevision.data == Data("null".utf8) { revision = nil }
        else { revision = try rawRevision.integerValue() }
        guard let state = RemoteHarnessBotCommandState(rawValue: try value.text("state")) else { throw RemoteHarnessError.invalidMessage }
        self.state = state
        let rawReason = try value.required("reason")
        if rawReason.data == Data("null".utf8) { reason = nil }
        else {
            guard let reason = RemoteHarnessBotCommandReason(rawValue: try rawReason.stringValue()) else { throw RemoteHarnessError.invalidMessage }
            self.reason = reason
        }
        guard (sessionID == nil) == (revision == nil), state != .accepted || (sessionID != nil && reason == nil),
              state != .notFound || (sessionID == nil && reason == nil),
              state != .rejected || (reason != nil && sessionID == nil),
              state != .uncertain || (reason == .dispatchUncertain && sessionID != nil) else { throw RemoteHarnessError.invalidMessage }
    }
    func validateAdmission(for submit: RemoteHarnessOperation) throws {
        guard state == .accepted || state == .uncertain else { return }
        let payload = try submit.params.fields().required("body").fields().required("payload").fields()
        guard sessionID?.utf8.elementsEqual(try payload.text("expectedSessionId").utf8) == true,
              revision == (try payload.required("expectedRevision").integerValue()) else { throw RemoteHarnessError.bindingMismatch }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        zip([lhs.workspaceID, lhs.botID, lhs.commandID], [rhs.workspaceID, rhs.botID, rhs.commandID]).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
            && lhs.sessionID.map { Data($0.utf8) } == rhs.sessionID.map { Data($0.utf8) }
            && lhs.revision == rhs.revision && lhs.state == rhs.state && lhs.reason == rhs.reason
    }
}
