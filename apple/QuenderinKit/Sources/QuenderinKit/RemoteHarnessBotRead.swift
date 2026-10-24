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
