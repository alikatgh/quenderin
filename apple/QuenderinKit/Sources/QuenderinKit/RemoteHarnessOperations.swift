import Foundation

public enum RemoteHarnessMethod: String, Sendable {
    case describe = "harness.transport.describe"
    case call = "harness.remote.call"
    case open = "harness.remote.stream.open"
    case close = "harness.remote.stream.close"
}

/// The first native journey deliberately has a fixed endpoint vocabulary.
/// Encoding an approval response does not authorize its dispatch.
public struct RemoteHarnessOperation: Sendable, Equatable, NativeConnectionPrivateValue {
    public let method: RemoteHarnessMethod
    public let params: RemoteHarnessJSON
    public let endpoint: String?
    public let streamID: String?
    public let sessionID: String?
    public let workspaceID: String?
    public let promptCommandID: String?
    public let isMutation: Bool
    let approvalClientID: String?
    let approvalEventID: String?
    let approvalAllows: Bool

    public init(method: RemoteHarnessMethod, params: RemoteHarnessJSON) throws {
        let fields = try params.fields()
        var endpoint: String?, streamID: String?, sessionID: String?, workspaceID: String?, promptID: String?
        var mutation = false, approvalClient: String?, approvalEvent: String?, approvalAllows = false
        switch method {
        case .describe: try fields.requireKeys([])
        case .close:
            try fields.requireKeys(["streamId"]); streamID = try fields.text("streamId")
        case .call, .open:
            try fields.requireKeys(method == .open ? ["streamId", "endpoint", "payload"] : ["endpoint", "payload"])
            if method == .open { streamID = try fields.text("streamId") }
            let name = try fields.text("endpoint"); endpoint = name
            let payload = try fields.required("payload").fields(); try payload.requireKeys(["args"])
            let args = try payload.required("args").fields()
            let callEndpoints: Set<String> = ["session/list", "session/create", "session/page", "session/prompt", "session/cancel", "$events/result", "session/modelCatalog", "session/selectModel"]
            let streamEndpoints: Set<String> = ["workspace/follow", "session/follow", "session/control", "$events"]
            guard (method == .call ? callEndpoints : streamEndpoints).contains(name) else { throw RemoteHarnessError.endpointNotAllowed }
            switch name {
            case "workspace/follow", "session/control", "$events", "session/modelCatalog": try args.requireKeys([])
            case "session/list":
                try args.requireKeys(["_request"]); try args.required("_request").fields().requireKeys([])
            case "session/create":
                try args.requireKeys(["request"])
                let request = try args.required("request").fields(); try request.requireKeys(["workspaceId"])
                workspaceID = try request.text("workspaceId"); mutation = true
            case "session/follow", "session/page":
                try args.requireKeys(["request"])
                let request = try args.required("request").fields()
                try request.requireKeys(name == "session/follow" ? ["address", "maxMessages", "assistantStream"] : ["address", "throughSeq", "beforeSeq", "maxMessages"])
                let address = try request.required("address").fields(); try address.requireKeys(["kind", "sessionId"])
                guard try address.text("kind") == "session", try request.required("maxMessages").integerValue() == 60 else { throw RemoteHarnessError.invalidMessage }
                sessionID = try address.text("sessionId")
                if name == "session/follow" {
                    guard try request.required("assistantStream").booleanValue() else { throw RemoteHarnessError.invalidMessage }
                } else {
                    let through = try request.required("throughSeq").integerValue(), before = try request.required("beforeSeq").integerValue()
                    guard before <= through else { throw RemoteHarnessError.invalidMessage }
                }
            case "session/prompt":
                try args.requireKeys(["request"])
                let request = try args.required("request").fields()
                try request.requireKeys(["requestId", "sessionId", "mode", "content"], optional: ["clientTimeZone"])
                promptID = try request.text("requestId"); sessionID = try request.text("sessionId")
                guard try request.text("mode") == "queue" else { throw RemoteHarnessError.invalidMessage }
                let content = try request.required("content").elements()
                guard content.count == 1 else { throw RemoteHarnessError.invalidMessage }
                let part = try content[0].fields(); try part.requireKeys(["type", "text"])
                let text = try part.required("text").stringValue()
                guard try part.text("type") == "text", !text.isEmpty, text.utf8.count <= RemoteHarnessLimits.promptBytes else { throw RemoteHarnessError.limitExceeded }
                if let zone = request["clientTimeZone"] {
                    let text = try zone.stringValue()
                    guard text == "UTC" || (text.utf8.count <= 128 && text.range(of: #"^[A-Za-z_]+/[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)?$"#, options: .regularExpression) != nil) else { throw RemoteHarnessError.invalidMessage }
                }
                mutation = true
            case "session/cancel", "session/selectModel":
                try args.requireKeys(["request"])
                let request = try args.required("request").fields()
                try request.requireKeys(name == "session/cancel" ? ["sessionId"] : ["sessionId", "provider", "model"], optional: name == "session/cancel" ? [] : ["reasoningEffort"])
                sessionID = try request.text("sessionId")
                if name == "session/selectModel" {
                    _ = try request.text("provider"); _ = try request.text("model")
                    if request["reasoningEffort"] != nil { _ = try request.text("reasoningEffort") }
                }
                mutation = true
            case "$events/result":
                try args.requireKeys(["clientId", "eventId", "outcome"])
                approvalClient = try args.text("clientId"); approvalEvent = try args.text("eventId")
                let outcome = try args.required("outcome").fields(); try outcome.requireKeys(["kind", "value"])
                let decision = try outcome.text("value")
                guard try outcome.text("kind") == "result", ["allowed-once", "rejected"].contains(decision) else { throw RemoteHarnessError.invalidMessage }
                approvalAllows = decision == "allowed-once"; mutation = true
            default: throw RemoteHarnessError.endpointNotAllowed
            }
        }
        self.method = method; self.params = params; self.endpoint = endpoint; self.streamID = streamID
        self.sessionID = sessionID; self.workspaceID = workspaceID; promptCommandID = promptID; isMutation = mutation
        approvalClientID = approvalClient; approvalEventID = approvalEvent; self.approvalAllows = approvalAllows
    }

    public static func describe() throws -> Self { try Self(method: .describe, params: .object([:])) }
    public static func sessionList() throws -> Self { try call("session/list", args: .object(["_request": .object([:])])) }
    public static func sessionCreate(workspaceID: String) throws -> Self { try call("session/create", args: .object(["request": .object(["workspaceId": .string(workspaceID)])])) }
    public static func modelCatalog() throws -> Self { try call("session/modelCatalog", args: .object([:])) }
    public static func prompt(commandID: String, sessionID: String, text: String, clientTimeZone: String? = nil) throws -> Self {
        var request: [String: RemoteHarnessJSON] = try ["requestId": .string(commandID), "sessionId": .string(sessionID), "mode": .string("queue"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])]
        if let clientTimeZone { request["clientTimeZone"] = try .string(clientTimeZone) }
        return try call("session/prompt", args: .object(["request": .object(request)]))
    }
    public static func cancel(sessionID: String) throws -> Self { try call("session/cancel", args: .object(["request": .object(["sessionId": .string(sessionID)])])) }
    public static func selectModel(sessionID: String, provider: String, model: String, reasoningEffort: String? = nil) throws -> Self {
        var request: [String: RemoteHarnessJSON] = try ["sessionId": .string(sessionID), "provider": .string(provider), "model": .string(model)]
        if let reasoningEffort { request["reasoningEffort"] = try .string(reasoningEffort) }
        return try call("session/selectModel", args: .object(["request": .object(request)]))
    }
    public static func page(sessionID: String, throughSeq: Int64, beforeSeq: Int64) throws -> Self {
        try call("session/page", args: .object(["request": .object(["address": address(sessionID), "throughSeq": .integer(throughSeq), "beforeSeq": .integer(beforeSeq), "maxMessages": .integer(60)])]))
    }
    public static func workspaceFollow(streamID: String) throws -> Self { try open("workspace/follow", streamID: streamID, args: .object([:])) }
    public static func sessionFollow(streamID: String, sessionID: String) throws -> Self {
        try open("session/follow", streamID: streamID, args: .object(["request": .object(["address": address(sessionID), "maxMessages": .integer(60), "assistantStream": .boolean(true)])]))
    }
    public static func control(streamID: String) throws -> Self { try open("session/control", streamID: streamID, args: .object([:])) }
    public static func events(streamID: String) throws -> Self { try open("$events", streamID: streamID, args: .object([:])) }
    public static func approvalResult(clientID: String, eventID: String, allow: Bool) throws -> Self {
        try call("$events/result", args: .object(["clientId": .string(clientID), "eventId": .string(eventID), "outcome": .object(["kind": .string("result"), "value": .string(allow ? "allowed-once" : "rejected")])]))
    }
    public static func close(streamID: String) throws -> Self { try Self(method: .close, params: .object(["streamId": .string(streamID)])) }
    private static func address(_ sessionID: String) throws -> RemoteHarnessJSON { try .object(["kind": .string("session"), "sessionId": .string(sessionID)]) }
    private static func call(_ endpoint: String, args: RemoteHarnessJSON) throws -> Self { try Self(method: .call, params: .object(["endpoint": .string(endpoint), "payload": .object(["args": args])])) }
    private static func open(_ endpoint: String, streamID: String, args: RemoteHarnessJSON) throws -> Self { try Self(method: .open, params: .object(["streamId": .string(streamID), "endpoint": .string(endpoint), "payload": .object(["args": args])])) }
}
