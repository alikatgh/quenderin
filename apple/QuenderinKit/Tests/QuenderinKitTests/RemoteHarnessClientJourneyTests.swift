import Foundation
import XCTest
@testable import QuenderinKit

/// All identities, credentials, network responses and inference are synthetic.
/// Production uses URLSession + the generated Rust SDK; this fixture proves
/// orchestration and persistence, not native rendering or real inference.
@MainActor private final class JourneyClock: RemoteHarnessClock {
    var nowEpochMilliseconds: Int64 = 1_000_000
    var monotonicMilliseconds: Int64 = 1_000
}
@MainActor private final class JourneyCrypto: RemoteHarnessCryptoBackend {
    var isAvailable = true
    func publicKey(privateSeed: Data) throws -> Data { Data(repeating: 7, count: 32) }
    func initiator(privateSeed: Data, peerPublicKey: Data, info: RemoteHarnessSecureConnectionInfo) throws -> any RemoteHarnessSecureNoise { JourneyNoise() }
}
@MainActor private final class JourneyNoise: RemoteHarnessSecureNoise {
    var complete = false, sending: Int64 = 0, receiving: Int64 = 0
    func initiate(emptyPayload: Data) throws -> Data { Data([1]) }
    func readHandshake(_ bytes: Data) throws -> RemoteHarnessSecureHandshakeResult { complete = true; return try .init(complete: true, payload: Data()) }
    func counters() throws -> RemoteHarnessSecureCounters { .init(complete: complete, sending: sending, receiving: receiving) }
    func encrypt(_ plaintext: Data) throws -> Data { sending += 1; return plaintext + Data(repeating: 0, count: 16) }
    func decrypt(_ ciphertext: Data) throws -> Data { receiving += 1; return Data(ciphertext.dropLast(16)) }
    func shutdown() throws {}
}
@MainActor private final class JourneyCredentials: RemoteHarnessClientCredentialStorage {
    var record: RemoteHarnessClientCredential?
    var saves = 0, failAtSave: Int?
    func load(origin: String) throws -> RemoteHarnessClientCredential? { record }
    func save(_ credential: RemoteHarnessClientCredential) throws {
        saves += 1; if saves == failAtSave { throw RemoteHarnessClientFailure.storage }; record = credential
    }
}
@MainActor private final class JourneyStorage: RemoteHarnessClientJournalStorage {
    var value: RemoteHarnessClientJournal?
    var failWrites = false
    func load() throws -> RemoteHarnessClientJournal? { value }
    func save(_ journal: RemoteHarnessClientJournal) throws { if failWrites { throw RemoteHarnessClientFailure.storage }; try journal.validate(); value = journal }
}
@MainActor private func journeyJSON(_ value: Any) throws -> RemoteHarnessJSON { try .init(data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }

/// Recorded by the pinned official Gateway/controllers/AgentLoop, with only the
/// model boundary scripted and one inert synthetic tool. Load the shared source
/// fixture as the existing digest tests do; no duplicated/corrected wire data.
@MainActor private final class JourneyOfficialRuntime {
    let frames: [[String: Any]]
    let unary: [String: [String: Any]]
    let hostTimestamp: Int64 = 2_000_000_000_000 - 60_000
    var nextFrame = 0
    var emittedFrames: [Int] = []
    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/remote-harness-official-runtime-facts.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["schema"] as? Int, 1)
        XCTAssertEqual(document["runtime"] as? String, "official-0.2.1-rc.1")
        XCTAssertEqual(document["source"] as? String, "1600d8a1e140dcde43a1a0941940a0480712c011")
        XCTAssertEqual(document["scriptedModelCalls"] as? Int, 2)
        XCTAssertEqual(document["inertToolExecutions"] as? Int, 1)
        frames = try XCTUnwrap(document["frames"] as? [[String: Any]])
        let calls = try XCTUnwrap(document["unary"] as? [[String: Any]])
        unary = try Dictionary(uniqueKeysWithValues: calls.map {
            (try XCTUnwrap($0["endpoint"] as? String), try XCTUnwrap($0["result"] as? [String: Any]))
        })
        XCTAssertEqual(frames.count, 47)
    }
    func result(_ endpoint: String) throws -> [String: Any] { try XCTUnwrap(unary[endpoint], endpoint) }
    func value(_ index: Int, hostID: String, clientID: String) throws -> [String: Any] {
        var value = try XCTUnwrap(frames[index]["value"] as? [String: Any])
        // Captured synthetic labels are not valid enrollment UUIDs. Rebind only
        // the two transport identities, outside the digested approval request.
        if var binding = value["quenderinBinding"] as? [String: Any] {
            XCTAssertEqual(binding["hostDeviceId"] as? String, "fixture-host")
            XCTAssertEqual(binding["clientDeviceId"] as? String, "fixture-native")
            binding["hostDeviceId"] = hostID; binding["clientDeviceId"] = clientID
            value["quenderinBinding"] = binding
        }
        return value
    }
}
@MainActor private final class JourneyServer: RemoteHarnessClientHTTP {
    let hostID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let hostKey = RemoteHarnessClientEncoding.base64(Data(repeating: 9, count: 32))
    var deviceID = ""
    var refreshRequests = 0, registrationRequests = 0, prompts = 0, approvals = 0, cancellations = 0
    var creations = 0, modelSelections = 0
    var companionAvailable = true
    var botCapabilities: [String] = []
    var botReads = 0, deferBotReads = false
    var botResponseOverride: [String: Any]?
    var sessionRowsOverride: [[String: Any]]?
    var workspaceSessionIDs: [String]?
    var snapshotActiveAttempt = false
    var snapshotTurnEvent: String?
    var loseRefresh = false, running = false, created = false
    var credentials: JourneyCredentials?
    var sockets: [JourneySocket] = []
    var official: JourneyOfficialRuntime?
    var now: Int64 = 1_000_000
    var lastPromptTimeZone: String?
    func pair(_ suffix: String = "a") -> [String: Any] { ["accessToken": "synthetic-access-token-" + suffix, "refreshToken": "synthetic-refresh-token-" + suffix, "accessTokenExpiresAt": now + 3_600_000, "refreshTokenExpiresAt": now + 2_592_000_000] }
    func host(descriptor: Bool) -> [String: Any] {
        var value: [String: Any] = ["deviceId": hostID, "name": "Synthetic computer", "role": "host", "platform": "linux", "membershipId": "synthetic-membership", "online": true, "clientVersion": "0.3.20", "lastSeenAt": now]
        if descriptor { value["identityKey"] = hostKey }; return value
    }
    func request(origin: String, path: String, method: String, bearer: String?, body: RemoteHarnessJSON?) async throws -> RemoteHarnessJSON {
        switch path {
        case "/api/v1/auth/login": return try journeyJSON(["account": "synthetic@example.test", "profile": ["displayName": "Synthetic"], "token": "synthetic-account-token", "expiresAt": now + 28_800_000])
        case "/api/v1/devices/register":
            registrationRequests += 1; let f = try body!.fields().required("device").fields(); deviceID = try f.text("deviceId")
            XCTAssertEqual(credentials?.record?.deviceID, deviceID, "identity reserved before dispatch")
            return try journeyJSON(pair())
        case "/api/v1/auth/refresh":
            refreshRequests += 1; XCTAssertNotNil(credentials?.record?.refreshAttemptID)
            if loseRefresh { throw RemoteHarnessClientFailure.connection }; return try journeyJSON(pair("rotated"))
        case "/api/v1/devices": return try journeyJSON(["items": [host(descriptor: false)], "nextCursor": NSNull()])
        case "/api/v1/devices/" + hostID: return try journeyJSON(host(descriptor: true))
        case "/api/v1/devices/" + hostID + "/presence": return try journeyJSON(["deviceId": hostID, "online": true, "lastSeenAt": now])
        default: throw RemoteHarnessClientFailure.protocolMismatch
        }
    }
    func makeSocket() -> any RemoteHarnessClientSocket { let socket = JourneySocket(server: self); sockets.append(socket); return socket }
    var sessionRow: [String: Any] { ["sessionId": "session-real", "updatedAt": now, "running": running, "blank": false, "title": "Synthetic task"] }
    var workspace: [String: Any] { ["workspaceId": "workspace-real", "path": "/synthetic/project", "title": "Synthetic workspace", "sessionIds": workspaceSessionIDs ?? (created ? ["session-real", "session-created"] : ["session-real"]), "createdAt": "2026-10-23", "updatedAt": "2026-10-23"] }
    func botResponse(workspaceID: String = "workspace-real", revision: Int = 7, bots: [[String: Any]]? = nil) -> [String: Any] {
        ["status": 200, "json": ["ok": true, "value": ["schemaVersion": 1, "workspaceId": workspaceID, "revision": revision, "readOnly": true,
            "bots": bots ?? [["id": "bot-real", "name": "Synthetic researcher", "sessionId": "session-real", "model": "deepseek-flash", "permission": "read-only"]]]]]
    }
}
@MainActor private final class JourneySocket: RemoteHarnessClientSocket {
    let server: JourneyServer
    let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
    var counter: Int64 = 0
    var streams: [String: String] = [:]
    var closed = false
    var relaySelected = false
    var receivedCount = 0
    var officialFrameLimit = 7
    var pendingBotReads: [String] = []
    var emittedOfficialFrames: [Int] { server.official?.emittedFrames ?? [] }
    init(server: JourneyServer) { self.server = server }
    func start(origin: String) throws { XCTAssertTrue(origin.hasPrefix("https://")) }
    func receive() async throws -> Data { var iterator = pair.stream.makeAsyncIterator(); guard let bytes = try await iterator.next() else { throw RemoteHarnessClientFailure.connection }; receivedCount += 1; return bytes }
    func close() { closed = true; pair.continuation.finish() }
    func control(_ type: String, _ payload: [String: Any]) throws {
        pair.continuation.yield(try journeyJSON(["v": 1, "id": UUID().uuidString, "type": type, "timestamp": server.now, "payload": payload]).data)
    }
    func business(_ type: String, _ payload: [String: Any]) throws {
        let data = try journeyJSON(["v": 1, "id": UUID().uuidString, "type": type, "timestamp": server.now, "payload": payload]).data + Data(repeating: 0, count: 16)
        try control("relay", ["connectionId": "fixture-connection", "targetDeviceId": server.deviceID, "counter": counter, "ciphertext": RemoteHarnessClientEncoding.base64(data)]); counter += 1
    }
    func frame(_ endpoint: String, _ value: [String: Any]) throws {
        guard let stream = streams[endpoint] else { return }
        try business("event", ["event": "harness.remote.frame", "data": ["streamId": stream, "hasValue": true, "value": value]])
    }
    func replyBotReads(_ result: [String: Any]? = nil) throws {
        let pending = pendingBotReads; pendingBotReads = []
        for id in pending { try business("rpc.response", ["requestId": id, "result": result ?? server.botResponseOverride ?? server.botResponse()]) }
    }
    func drainOfficialFrames() throws {
        guard let official = server.official else { return }
        let endpoints = ["workspace-feed": "workspace/follow", "session-history": "session/follow", "session-control": "session/control", "remote-events": "$events"]
        while official.nextFrame < officialFrameLimit {
            let captured = official.frames[official.nextFrame]
            let endpoint = try XCTUnwrap(endpoints[try XCTUnwrap(captured["streamId"] as? String)])
            guard streams[endpoint] != nil else { return }
            XCTAssertEqual(captured["event"] as? String, "harness.remote.frame")
            XCTAssertEqual(captured["hasValue"] as? Bool, true)
            try frame(endpoint, official.value(official.nextFrame, hostID: server.hostID, clientID: server.deviceID))
            official.emittedFrames.append(official.nextFrame); official.nextFrame += 1
        }
    }
    func enqueue(_ bytes: Data, failed: @escaping @MainActor () -> Void) throws {
        let f = try RemoteHarnessJSON(data: bytes).fields(), type = try f.text("type"), p = try f.required("payload").fields()
        switch type {
        case "hello":
            XCTAssertEqual(try p.text("deviceId"), server.deviceID)
            try control("hello.ack", ["protocol": 1, "serverVersion": "synthetic", "connectionSessionId": "not-noise-id", "heartbeatIntervalMs": 25000, "maxControlFrameBytes": 65536, "maxRelayFrameBytes": 1048576, "capabilities": ["transport.relay"]])
        case "connect.request": try control("connect.accepted", ["connectionId": "fixture-connection"])
        case "transport.selected": relaySelected = true
        case "secure.handshake":
            XCTAssertTrue(relaySelected); XCTAssertEqual(try p.text("connectionId"), "fixture-connection")
            try control("secure.handshake", ["connectionId": "fixture-connection", "targetDeviceId": server.deviceID, "step": 2, "data": "Ag"])
        case "ping": try control("pong", ["nonce": p.text("nonce")])
        case "relay":
            let encoded = try p.text("ciphertext"), standard = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let raw = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))!
            let rpc = try RemoteHarnessJSON(data: Data(raw.dropLast(16))).fields(), rpcID = try rpc.text("id"), payload = try rpc.required("payload").fields(), method = try payload.text("method"), params = try payload.required("params").fields()
            if method == "harness.transport.describe" {
                let capabilities = (server.companionAvailable ? ["harness.remote.v3", "quenderin.approvals.v1"] : ["harness.remote.v3"]) + server.botCapabilities
                try business("rpc.response", ["requestId": rpcID, "result": ["capabilities": capabilities]]); return
            }
            if method == "plugin.route.call" {
                XCTAssertEqual(try params.text("route"), "api/bot")
                let body = try params.required("body").fields(), request = try body.required("payload").fields()
                XCTAssertEqual(try body.text("endpoint"), "quenderin-roster")
                XCTAssertEqual(try request.required("schemaVersion").integerValue(), 1)
                XCTAssertEqual(try request.text("workspaceId"), "workspace-real")
                server.botReads += 1
                if server.deferBotReads { pendingBotReads.append(rpcID) }
                else { try business("rpc.response", ["requestId": rpcID, "result": server.botResponseOverride ?? server.botResponse()]) }
                return
            }
            if method == "harness.remote.stream.open" {
                let endpoint = try params.text("endpoint"), stream = try params.text("streamId"); streams[endpoint] = stream
                if let official = server.official {
                    if endpoint == "workspace/follow", official.nextFrame >= 4 {
                        // Native selection opens a fresh scoped connection.
                        // The capture's initial empty baseline predates workspace
                        // creation, so supply a fixture-only current baseline from
                        // its exact final upsert. Captured frames replay once.
                        let workspace = try XCTUnwrap(official.frames[3]["value"] as? [String: Any])["workspace"]
                        try frame(endpoint, ["type": "baseline", "value": ["items": [try XCTUnwrap(workspace)], "archivedSessionIds": []]])
                    }
                    if endpoint == "session/follow" {
                        let request = try params.required("payload").fields().required("args").fields().required("request").fields()
                        XCTAssertEqual(try request.required("address").fields().text("sessionId"), "fixture-session")
                        XCTAssertEqual(try request.required("maxMessages").integerValue(), 60)
                        XCTAssertTrue(try request.required("assistantStream").booleanValue())
                    }
                    try drainOfficialFrames()
                    try business("rpc.response", ["requestId": rpcID, "result": ["streamId": stream, "opened": true]]); return
                }
                if endpoint == "workspace/follow" { try frame(endpoint, ["type": "baseline", "value": ["items": [server.workspace], "archivedSessionIds": []]]) }
                if endpoint == "session/follow" {
                    let sessionID = try params.required("payload").fields().required("args").fields().required("request").fields().required("address").fields().text("sessionId")
                    var records: [[String: Any]] = [["type": "event", "event": ["type": "user/message", "seq": 1, "time": server.now, "data": ["text": "Synthetic earlier task"]]]]
                    if let name = server.snapshotTurnEvent { records.append(["type": "event", "event": ["type": name, "seq": 2, "time": server.now, "data": ["turn": 1]]]) }
                    let cursor = records.count
                    var snapshot: [String: Any] = ["type": "snapshot", "header": ["id": sessionID], "records": records, "cursor": cursor, "hasMore": false]
                    if server.snapshotActiveAttempt {
                        snapshot["assistantStream"] = ["revision": 5, "activeAttempt": ["attemptId": "snapshot-active", "nextIndex": 1, "startedAfterSeq": cursor, "turn": 1, "step": 0, "stream": [["type": "text-chunks", "texts": ["Synthetic in-progress answer"]]]]]
                    }
                    try frame(endpoint, snapshot)
                }
                if endpoint == "$events" { try frame(endpoint, ["type": "ready", "clientId": "event-client"]) }
                try business("rpc.response", ["requestId": rpcID, "result": ["streamId": stream, "opened": true]]); return
            }
            let endpoint = try params.text("endpoint")
            if let official = server.official, ["session/list", "session/prompt", "quenderin/approval"].contains(endpoint) {
                // Repeat the exact captured discovery list for the controller's
                // extra reconciliation reads. Model catalog/enrollment remain
                // fixture-only setup, separate from official runtime evidence.
                let args = try params.required("payload").fields().required("args").fields()
                if endpoint == "session/prompt" {
                    let request = try args.required("request").fields()
                    XCTAssertEqual(try request.text("sessionId"), "fixture-session")
                    XCTAssertEqual(try request.required("content").elements().first?.fields().text("text"), "Run the synthetic fixture tool once.")
                    server.prompts += 1; officialFrameLimit = 23
                } else if endpoint == "quenderin/approval" {
                    XCTAssertEqual(try args.text("clientId"), "fixture-event-client")
                    let binding = try args.required("binding").fields()
                    XCTAssertEqual(try binding.text("hostDeviceId"), server.hostID)
                    XCTAssertEqual(try binding.text("clientDeviceId"), server.deviceID)
                    XCTAssertEqual(try binding.text("eventId"), "fixture-event")
                    XCTAssertEqual(try binding.text("actionDigest"), "b632e1a5465329596c354592f48935e41ea8bea2035485211190ddaf0607f813")
                    XCTAssertEqual(try args.required("outcome").fields().text("value"), "allowed-once")
                    server.approvals += 1; officialFrameLimit = official.frames.count
                }
                try drainOfficialFrames()
                try business("rpc.response", ["requestId": rpcID, "result": official.result(endpoint)]); return
            }
            var value: Any = NSNull()
            switch endpoint {
            case "session/list": value = ["items": server.sessionRowsOverride ?? (server.created ? [server.sessionRow, ["sessionId": "session-created", "updatedAt": server.now, "running": false, "blank": true, "title": "New synthetic session"]] : [server.sessionRow])]
            case "session/create": server.creations += 1; server.created = true; value = ["sessionId": "session-created"]
            case "session/modelCatalog": value = ["default": ["provider": "synthetic", "model": "deepseek-harness", "reasoningEffort": "high"], "groups": [["id": "synthetic", "name": "Synthetic provider", "models": [["id": "deepseek-harness", "name": "Synthetic DeepSeek", "reasoning": ["efforts": [["id": "high", "name": "High"]]]]]]]]
            case "session/selectModel": server.modelSelections += 1; value = ["selected": ["provider": "synthetic", "model": "deepseek-harness", "reasoningEffort": "high"]]
            case "session/prompt":
                server.lastPromptTimeZone = try params.required("payload").fields().required("args").fields().required("request").fields()["clientTimeZone"]?.stringValue()
                server.prompts += 1; server.running = true
                try frame("session/follow", ["type": "event", "event": ["type": "turn/start", "seq": 2, "time": server.now, "data": ["turn": 1]]])
                try frame("session/follow", ["type": "assistant-stream", "frame": ["type": "start", "revision": 1, "attemptId": "attempt-real", "startedAfterSeq": 2, "turn": 1, "step": 0]])
                try frame("session/follow", ["type": "assistant-stream", "frame": ["type": "chunk", "revision": 2, "attemptId": "attempt-real", "index": 0, "time": server.now, "chunk": ["type": "reasoning-delta", "text": "Synthetic reasoning"]]])
                try frame("session/follow", ["type": "assistant-stream", "frame": ["type": "chunk", "revision": 3, "attemptId": "attempt-real", "index": 1, "time": server.now, "chunk": ["type": "text-delta", "text": "Synthetic streamed answer"]]])
                try frame("session/follow", ["type": "event", "event": ["type": "tool/call", "seq": 3, "time": server.now, "data": ["turn": 1, "callId": "synthetic-call", "name": "read_file", "arguments": "{}"]]])
                let request = ["toolName": "read_file", "callId": "synthetic-call", "reason": "Synthetic tool"]
                let digest = try RemoteHarnessApprovalDigest.digest(journeyJSON(request))
                try frame("$events", ["type": "waterfall", "event": "approval/request", "eventId": "approval-real", "agentId": "session-real", "request": request, "quenderinBinding": ["hostDeviceId": server.hostID, "clientDeviceId": server.deviceID, "workspaceId": "workspace-real", "sessionId": "session-real", "runId": "turn:1", "eventId": "approval-real", "actionDigest": digest, "expiresAt": server.now + 60_000]])
            case "quenderin/approval": server.approvals += 1; value = ["recorded": true]
            case "session/cancel": server.cancellations += 1; value = ["accepted": true]
            default: throw RemoteHarnessClientFailure.protocolMismatch
            }
            try business("rpc.response", ["requestId": rpcID, "result": ["ok": true, "value": value]])
        default: throw RemoteHarnessClientFailure.protocolMismatch
        }
    }
}

@MainActor final class RemoteHarnessClientJourneyTests: XCTestCase {
    private func actionApproval(sessionID: String = "session-real", runID: String = "turn:1", callID: String = "call-real", toolName: String = "read_file") throws -> RemoteHarnessPendingApproval {
        let binding = try RemoteHarnessBinding(generation: 1, hostID: "host", workspaceID: "workspace-real", sessionID: sessionID, clientDeviceID: "client")
        let extended = try RemoteHarnessApprovalBinding(journeyJSON(["hostDeviceId": "host", "clientDeviceId": "client", "workspaceId": "workspace-real", "sessionId": sessionID,
            "runId": runID, "eventId": "approval-real", "actionDigest": String(repeating: "a", count: 64), "expiresAt": 1_060_000]))
        return .init(clientID: "event-client", eventID: "approval-real", binding: binding,
            request: try journeyJSON(["toolName": toolName, "callId": callID]), extensionBinding: extended, hostTimestamp: 1_000_000)
    }
    private func actionCall(_ arguments: String = "{}", callID: String = "call-real", name: String = "read_file", turn: Int = 1) -> [String: Any] {
        ["turn": turn, "callId": callID, "name": name, "arguments": arguments]
    }
    private func actionTimeline(_ calls: [[String: Any]]) throws -> RemoteHarnessClientTimeline {
        var timeline = RemoteHarnessClientTimeline()
        var records: [[String: Any]] = [["type": "event", "event": ["type": "turn/start", "seq": 0, "time": 1, "data": ["turn": 1]]]]
        for (index, call) in calls.enumerated() { records.append(["type": "event", "event": ["type": "tool/call", "seq": index + 1, "time": 1, "data": call]]) }
        try timeline.receive(journeyJSON(["type": "snapshot", "header": ["id": "session-real"], "cursor": records.count - 1, "hasMore": false, "records": records]), expectedSessionID: "session-real")
        return timeline
    }
    func testApprovalActionRequiresExactlyOneDurableCallInTheActiveScope() throws {
        let arguments = "{ \"path\": \"/synthetic/" + String(repeating: "long file ", count: 600) + "\", \"nested\": [1, 2] }\n"
        let approval = try actionApproval()
        var timeline = try actionTimeline([actionCall(arguments)])
        XCTAssertEqual(timeline.approvalAction(for: approval)?.arguments, arguments, "presentation preserves every argument byte without truncation/reformatting")
        XCTAssertNil(timeline.approvalAction(for: try actionApproval(callID: "missing")))
        XCTAssertNil(timeline.approvalAction(for: try actionApproval(toolName: "write_file")))
        XCTAssertNil(timeline.approvalAction(for: try actionApproval(runID: "turn:2")))
        XCTAssertNil(timeline.approvalAction(for: try actionApproval(sessionID: "another-session")))
        XCTAssertNil(try actionTimeline([]).approvalAction(for: approval))
        for calls in [
            [actionCall("{}"), actionCall("{}")],
            [actionCall("{}"), actionCall("{\"changed\":true}")],
            [actionCall("{}"), actionCall("{}", name: "write_file")],
            [actionCall("not-json")], [actionCall("{}", turn: 2)],
            [["turn": 1, "callId": "call-real", "name": "read_file"]],
            [["turn": 1, "callId": "call-real", "name": "read_file", "arguments": 4]],
            [["turn": 1, "callId": "call-real", "name": "read_file", "arguments": "{}", "sessionId": "another-session"]]
        ] {
            XCTAssertNil(try actionTimeline(calls).approvalAction(for: approval))
        }
        try timeline.receive(journeyJSON(["type": "event", "event": ["type": "turn/end", "seq": 2, "time": 1, "data": ["turn": 1]]]), expectedSessionID: "session-real")
        XCTAssertNil(timeline.approvalAction(for: approval)); XCTAssertFalse(timeline.hasActiveTurn)
        timeline = try actionTimeline([actionCall(arguments)])
        let saved = timeline.records; try timeline.restore(saved)
        XCTAssertNil(timeline.approvalAction(for: approval), "saved history is not fresh approval evidence")
        timeline = try actionTimeline([actionCall(arguments)]); timeline.clearApprovalEvidence()
        XCTAssertNil(timeline.approvalAction(for: approval))
    }
    func testApprovalEvidenceBoundsWithholdActionWithoutDiscardingHistoryOrActiveTurn() throws {
        let approval = try actionApproval()
        let oversized = "{\"text\":\"" + String(repeating: "x", count: RemoteHarnessClientTimeline.maximumApprovalArgumentBytes) + "\"}"
        let malformedThenValid = try actionTimeline([actionCall(oversized), actionCall("{}")])
        XCTAssertNil(malformedThenValid.approvalAction(for: approval)); XCTAssertTrue(malformedThenValid.hasActiveTurn)
        XCTAssertEqual(malformedThenValid.records.count, 3)
        let tooMany = (0...RemoteHarnessClientTimeline.maximumApprovalCalls).map { actionCall("{}", callID: "call-\($0)") }
        let countLimited = try actionTimeline(tooMany)
        XCTAssertNil(countLimited.approvalAction(for: try actionApproval(callID: "call-0"))); XCTAssertTrue(countLimited.hasActiveTurn)
        XCTAssertEqual(countLimited.records.count, tooMany.count + 1)
        let large = "{\"text\":\"" + String(repeating: "x", count: 65_000) + "\"}"
        let byteLimited = try actionTimeline((0..<5).map { actionCall(large, callID: "call-\($0)") })
        XCTAssertNil(byteLimited.approvalAction(for: try actionApproval(callID: "call-0"))); XCTAssertTrue(byteLimited.hasActiveTurn)
        XCTAssertEqual(byteLimited.records.count, 6)
    }
    func testRepeatedAndLowerTurnsCannotResetDuplicateOrOverflowEvidence() throws {
        let overflow = (0...RemoteHarnessClientTimeline.maximumApprovalCalls).map { actionCall("{}", callID: "call-\($0)") }
        for calls in [[actionCall(), actionCall()], overflow] {
            var timeline = try actionTimeline(calls)
            var seq = calls.count + 1
            func event(_ type: String, _ data: [String: Any]) throws -> RemoteHarnessJSON {
                defer { seq += 1 }
                return try journeyJSON(["type": "event", "event": ["type": type, "seq": seq, "time": 1, "data": data]])
            }
            XCTAssertNil(timeline.approvalAction(for: try actionApproval()))
            try timeline.receive(event("turn/start", ["turn": 1]), expectedSessionID: "session-real")
            try timeline.receive(event("tool/call", actionCall()), expectedSessionID: "session-real")
            XCTAssertNil(timeline.approvalAction(for: try actionApproval()), "repeating the same run cannot erase previous evidence")
            try timeline.receive(event("turn/start", ["turn": 0]), expectedSessionID: "session-real")
            try timeline.receive(event("tool/call", actionCall(turn: 0)), expectedSessionID: "session-real")
            XCTAssertNil(timeline.approvalAction(for: try actionApproval(runID: "turn:0")), "a lower run identifier cannot reset the scope")
            try timeline.receive(event("turn/start", ["turn": 1]), expectedSessionID: "session-real")
            try timeline.receive(event("tool/call", actionCall()), expectedSessionID: "session-real")
            XCTAssertNil(timeline.approvalAction(for: try actionApproval()))
            XCTAssertTrue(timeline.hasActiveTurn); XCTAssertEqual(timeline.records.count, calls.count + 7)
            try timeline.receive(event("turn/start", ["turn": 2]), expectedSessionID: "session-real")
            try timeline.receive(event("tool/call", actionCall(turn: 2)), expectedSessionID: "session-real")
            XCTAssertNotNil(timeline.approvalAction(for: try actionApproval(runID: "turn:2")), "a strictly newer run starts a fresh bounded scope")
            try timeline.receive(event("turn/end", ["turn": 2]), expectedSessionID: "session-real")
            try timeline.receive(event("turn/start", ["turn": 2]), expectedSessionID: "session-real")
            try timeline.receive(event("tool/call", actionCall(turn: 2)), expectedSessionID: "session-real")
            XCTAssertNil(timeline.approvalAction(for: try actionApproval(runID: "turn:2")), "closing a turn cannot permit reuse of its identifier")
        }
    }
    func testApprovalAggregateBoundChargesCallIdentityAndToolNameBytes() throws {
        let name = String(repeating: "n", count: 1024)
        let arguments = "{\"v\":\"" + String(repeating: "x", count: 2040) + "\"}"
        func callID(_ index: Int) -> String { let suffix = String(index); return String(repeating: "i", count: 1024 - suffix.utf8.count) + suffix }
        var timeline = try actionTimeline((0..<63).map { actionCall(arguments, callID: callID($0), name: name) })
        let approval = try actionApproval(callID: callID(0), toolName: name)
        XCTAssertNotNil(timeline.approvalAction(for: approval))
        try timeline.receive(journeyJSON(["type": "event", "event": ["type": "tool/call", "seq": 64, "time": 1,
            "data": actionCall(arguments, callID: callID(63), name: name)]]), expectedSessionID: "session-real")
        XCTAssertNil(timeline.approvalAction(for: approval), "identities plus arguments exceed 256 KiB well below 128 calls")
        XCTAssertTrue(timeline.hasActiveTurn); XCTAssertEqual(timeline.records.count, 65)
    }
    func testSameRunSnapshotCannotErasePoisonedEvidence() throws {
        var timeline = try actionTimeline([actionCall(), actionCall()])
        let records: [[String: Any]] = [
            ["type": "event", "event": ["type": "turn/start", "seq": 3, "time": 1, "data": ["turn": 1]]],
            ["type": "event", "event": ["type": "tool/call", "seq": 4, "time": 1, "data": actionCall()]]
        ]
        try timeline.receive(journeyJSON(["type": "snapshot", "header": ["id": "session-real"], "cursor": 4, "hasMore": true, "records": records]), expectedSessionID: "session-real")
        XCTAssertNil(timeline.approvalAction(for: try actionApproval())); XCTAssertTrue(timeline.hasActiveTurn)
        let earlier: [String: Any] = ["type": "event", "event": ["type": "user/message", "seq": 2, "time": 1, "data": ["text": "Earlier"]]]
        try timeline.prependPage(journeyJSON(["records": [earlier], "hasMore": false]))
        XCTAssertNil(timeline.approvalAction(for: try actionApproval()), "paging must retain the same-run poison latch")
    }
    func testSameRunSnapshotPreservesImmutableCallIdentitySequenceAndExactArguments() throws {
        func snapshot(_ arguments: String?, sequence: Int = 1, name: String = "read_file", callID: String = "call-real") throws -> RemoteHarnessJSON {
            var records: [[String: Any]] = [["type": "event", "event": ["type": "turn/start", "seq": 0, "time": 1, "data": ["turn": 1]]]]
            if let arguments { records.append(["type": "event", "event": ["type": "tool/call", "seq": sequence, "time": 1, "data": actionCall(arguments, callID: callID, name: name)]]) }
            return try journeyJSON(["type": "snapshot", "header": ["id": "session-real"], "cursor": max(1, sequence), "hasMore": false, "records": records])
        }
        let approval = try actionApproval()
        var timeline = try actionTimeline([actionCall()])
        let original = try XCTUnwrap(timeline.approvalAction(for: approval))
        XCTAssertEqual(original.sequence, 1)
        try timeline.receive(snapshot("{}"), expectedSessionID: "session-real")
        XCTAssertEqual(timeline.approvalAction(for: approval), original, "identical call fields at the same durable sequence are idempotent")
        for (arguments, sequence, name, callID) in [
            ("{\"changed\":true}", 1, "read_file", "call-real"),
            ("{}", 2, "read_file", "call-real"),
            ("{}", 1, "write_file", "call-real"),
            ("{}", 1, "read_file", "another-call")
        ] {
            var changed = try actionTimeline([actionCall()])
            try changed.receive(snapshot(arguments, sequence: sequence, name: name, callID: callID), expectedSessionID: "session-real")
            XCTAssertNil(changed.approvalAction(for: try actionApproval(callID: callID, toolName: name)))
            XCTAssertTrue(changed.hasActiveTurn); XCTAssertEqual(changed.records.count, 2)
        }
        try timeline.receive(snapshot(nil), expectedSessionID: "session-real")
        XCTAssertNil(timeline.approvalAction(for: approval))
        try timeline.receive(snapshot("{\"changed\":true}"), expectedSessionID: "session-real")
        XCTAssertNil(timeline.approvalAction(for: approval), "removal cannot erase immutable-call continuity")
        try timeline.receive(snapshot("{}"), expectedSessionID: "session-real")
        XCTAssertNil(timeline.approvalAction(for: approval), "returning the original payload cannot erase the poison latch")
        let composed = "{\"text\":\"\u{e9}\"}", decomposed = "{\"text\":\"e\u{301}\"}"
        XCTAssertEqual(composed, decomposed); XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        var unicode = try actionTimeline([actionCall(composed)])
        try unicode.receive(snapshot(decomposed), expectedSessionID: "session-real")
        XCTAssertNil(unicode.approvalAction(for: approval), "argument comparison uses exact UTF-8 rather than Unicode-normalized String equality")
    }
    func testHistoricalPagePreservesSnapshotActiveRunAndFindsDuplicateCalls() throws {
        var timeline = RemoteHarnessClientTimeline()
        let call: [String: Any] = ["type": "event", "event": ["type": "tool/call", "seq": 10, "time": 1, "data": actionCall()]]
        try timeline.receive(journeyJSON(["type": "snapshot", "header": ["id": "session-real"], "cursor": 10, "hasMore": true, "records": [call],
            "assistantStream": ["revision": 1, "activeAttempt": ["attemptId": "active", "nextIndex": 0, "startedAfterSeq": 10, "turn": 1, "step": 1, "stream": []]]]), expectedSessionID: "session-real")
        let approval = try actionApproval()
        XCTAssertNotNil(timeline.approvalAction(for: approval))
        let earlier: [String: Any] = ["type": "event", "event": ["type": "user/message", "seq": 9, "time": 1, "data": ["text": "Earlier"]]]
        try timeline.prependPage(journeyJSON(["records": [earlier], "hasMore": true]))
        XCTAssertNotNil(timeline.approvalAction(for: approval)); XCTAssertTrue(timeline.hasActiveTurn)
        let duplicate: [String: Any] = ["type": "event", "event": ["type": "tool/call", "seq": 8, "time": 1, "data": actionCall()]]
        try timeline.prependPage(journeyJSON(["records": [duplicate], "hasMore": false]))
        XCTAssertNil(timeline.approvalAction(for: approval)); XCTAssertTrue(timeline.hasActiveTurn)
    }
    #if !canImport(CryptoKit)
    func testApprovalDigestFailsClosedWithoutNativeSHA256() throws {
        XCTAssertThrowsError(try RemoteHarnessApprovalDigest.digest(journeyJSON(["toolName": "read_file"]))) {
            XCTAssertEqual($0 as? RemoteHarnessError, .approvalBindingUnavailable)
        }
    }
    #endif
    func testActionCanonicalizationMatchesHostJSONFixtures() throws {
        let fixtures = [
            (#"{"z":1e20,"a":-0,"m":1e-7,"slash":"a/b","2":2,"10":10}"#, #"{"2":2,"10":10,"a":0,"m":1e-7,"slash":"a/b","z":100000000000000000000}"#),
            (#"{"nested":{"z":true,"a":[null,1.0,0.000001,1e21]},"toolName":"read_file"}"#, #"{"nested":{"a":[null,1,0.000001,1e+21],"z":true},"toolName":"read_file"}"#)
        ]
        for (input, expected) in fixtures {
            var nodes = 0; let bytes = try RemoteHarnessApprovalDigest.canonical(.init(data: Data(input.utf8)), nodes: &nodes)
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected)
        }
    }
    func testSharedApprovalDigestFixturesUseExplicitSwiftExpectations() throws {
        struct Fixture: Decodable {
            let id: String
            let wireJSON: String
            let canonicalJSON: String?
            let sha256: String?
            let nativeExpectation: String
            let swiftExpectation: String?
        }
        struct Document: Decodable { let schemaVersion: Int; let cases: [Fixture] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: root.appendingPathComponent("shared/remote-harness-approval-digest-fixtures.json")))
        XCTAssertEqual(document.schemaVersion, 1); XCTAssertGreaterThanOrEqual(document.cases.count, 12)
        XCTAssertEqual(Set(document.cases.map(\.id)).count, document.cases.count)
        for fixture in document.cases {
            let expectation = fixture.swiftExpectation ?? fixture.nativeExpectation
            if expectation == "reject" {
                var nodes = 0
                XCTAssertThrowsError(try RemoteHarnessApprovalDigest.canonical(.init(data: Data(fixture.wireJSON.utf8)), nodes: &nodes), fixture.id)
            } else {
                XCTAssertEqual(expectation, "digest", fixture.id)
                let value = try RemoteHarnessJSON(data: Data(fixture.wireJSON.utf8)); var nodes = 0
                let canonical = try RemoteHarnessApprovalDigest.canonical(value, nodes: &nodes)
                XCTAssertEqual(String(decoding: canonical, as: UTF8.self), try XCTUnwrap(fixture.canonicalJSON), fixture.id)
                #if canImport(CryptoKit)
                XCTAssertEqual(try RemoteHarnessApprovalDigest.digest(value), try XCTUnwrap(fixture.sha256), fixture.id)
                #endif
            }
        }
    }
    func testSessionSnapshotRejectsWrongSessionAndGaps() throws {
        var timeline = RemoteHarnessClientTimeline()
        let snapshot = try journeyJSON(["type": "snapshot", "header": ["id": "real-session"], "cursor": 4, "hasMore": false, "records": [["type": "event", "event": ["type": "user/message", "seq": 4, "time": 1, "data": ["text": "Earlier"]]]]])
        XCTAssertThrowsError(try timeline.receive(snapshot, expectedSessionID: "wrong-session"))
        try timeline.receive(snapshot, expectedSessionID: "real-session")
        let gap = try journeyJSON(["type": "event", "event": ["type": "turn/start", "seq": 6, "time": 1, "data": ["turn": 1]]])
        XCTAssertThrowsError(try timeline.receive(gap, expectedSessionID: "real-session"))
        XCTAssertEqual(timeline.cursor, 4)
    }
    func testOfficialRuntimeEmptySnapshotAndOrderedHistoryMatchNativeTimeline() throws {
        let official = try JourneyOfficialRuntime()
        let snapshot = try journeyJSON(official.value(4, hostID: "unused", clientID: "unused"))
        let fields = try snapshot.fields()
        XCTAssertEqual(try fields.required("header").fields().required("version").integerValue(), 4)
        XCTAssertEqual(try fields.required("projections").fields().required("asOfSeq").data, Data("-1".utf8))
        XCTAssertNotNil(try fields.required("projections").fields().required("values").fields()["workingDirectory"])
        var timeline = RemoteHarnessClientTimeline()
        XCTAssertThrowsError(try timeline.receive(snapshot, expectedSessionID: "another-session"))
        try timeline.receive(snapshot, expectedSessionID: "fixture-session")
        XCTAssertEqual(timeline.cursor, -1); XCTAssertTrue(timeline.rows.isEmpty)
        for index in 7..<official.frames.count where official.frames[index]["streamId"] as? String == "session-history" {
            try timeline.receive(journeyJSON(official.value(index, hostID: "unused", clientID: "unused")), expectedSessionID: "fixture-session")
        }
        XCTAssertEqual(timeline.records.count, 19)
        XCTAssertEqual(try RemoteHarnessJSON(data: XCTUnwrap(timeline.records.first)).fields().required("event").fields().required("seq").integerValue(), 0)
        XCTAssertEqual(try RemoteHarnessJSON(data: XCTUnwrap(timeline.records.last)).fields().required("event").fields().required("seq").integerValue(), 18)
        XCTAssertTrue(timeline.rows.contains { $0.kind == "user" && $0.text == "Run the synthetic fixture tool once." })
        XCTAssertTrue(timeline.rows.contains { $0.kind == "tool" && $0.text == "synthetic result" })
        XCTAssertEqual(timeline.rows.filter { $0.kind == "assistant" && $0.text == "Synthetic tool completed." }.count, 1,
                       "durable assistant/message precedes attempt end and must replace transient text")
    }
    func testEmptySnapshotSentinelDoesNotRelaxOtherCursorOrEventValidation() throws {
        func snapshot(_ cursor: Any, records: [[String: Any]] = []) throws -> RemoteHarnessJSON {
            try journeyJSON(["type": "snapshot", "header": ["id": "fixture-session"], "cursor": cursor, "hasMore": false, "records": records])
        }
        let event: [String: Any] = ["type": "event", "event": ["type": "user/message", "seq": 0, "time": 1, "data": ["text": "First"]]]
        for invalid: Any in [-2, -1.5, "-1"] {
            var timeline = RemoteHarnessClientTimeline()
            XCTAssertThrowsError(try timeline.receive(snapshot(invalid), expectedSessionID: "fixture-session"))
        }
        var timeline = RemoteHarnessClientTimeline()
        XCTAssertThrowsError(try timeline.receive(snapshot(-1, records: [event]), expectedSessionID: "fixture-session"))
        let decimalCursor = String(decoding: try snapshot(-1).data, as: UTF8.self).replacingOccurrences(of: "\"cursor\":-1", with: "\"cursor\":-1.0")
        XCTAssertThrowsError(try timeline.receive(.init(data: Data(decimalCursor.utf8)), expectedSessionID: "fixture-session"))
        try timeline.receive(snapshot(-1), expectedSessionID: "fixture-session")
        let skipped = try journeyJSON(["type": "event", "event": ["type": "user/message", "seq": 1, "time": 1, "data": ["text": "Gap"]]])
        XCTAssertThrowsError(try timeline.receive(skipped, expectedSessionID: "fixture-session"))
        try timeline.receive(journeyJSON(event), expectedSessionID: "fixture-session")
        XCTAssertEqual(timeline.earliestSequence, 0)
        let negative = try journeyJSON(["type": "event", "event": ["type": "user/message", "seq": -1, "time": 1, "data": ["text": "Invalid"]]])
        XCTAssertThrowsError(try timeline.receive(negative, expectedSessionID: "fixture-session"))
    }
    func testMidResponseSnapshotRestoresTextReasoningAndToolsBeforeTail() throws {
        var timeline = RemoteHarnessClientTimeline()
        try timeline.receive(journeyJSON(["type": "snapshot", "header": ["id": "real-session"], "cursor": 4, "hasMore": false, "records": [], "assistantStream": ["revision": 7, "activeAttempt": ["attemptId": "active", "nextIndex": 4, "startedAfterSeq": 4, "turn": 2, "step": 0, "stream": [["type": "text-chunks", "texts": ["Prior ", "text"]], ["type": "reasoning-chunks", "texts": ["Prior reasoning"]], ["type": "tool-call-chunks", "id": "tool", "name": "read_file", "args": ["{\"path\":\"file\"}"]]]]]]), expectedSessionID: "real-session")
        XCTAssertTrue(timeline.rows.contains { $0.text == "Prior text" }); XCTAssertTrue(timeline.rows.contains { $0.text == "Prior reasoning" }); XCTAssertTrue(timeline.rows.contains { $0.kind == "tool" })
        try timeline.receive(journeyJSON(["type": "assistant-stream", "frame": ["type": "chunk", "attemptId": "active", "revision": 8, "index": 4, "time": 1, "chunk": ["type": "text-delta", "text": " tail"]]]), expectedSessionID: "real-session")
        XCTAssertTrue(timeline.rows.contains { $0.text.contains("tail") }); XCTAssertEqual(timeline.cursor, 4)
    }
    func testLostSingleUseRefreshNeverReplaysAcrossRelaunch() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        let account = RemoteHarnessClientAccount(http: server, storage: vault, backend: crypto, clock: clock, randomSeed: { Data(repeating: 1, count: 32) })
        let enrolled = try await account.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        XCTAssertEqual(server.registrationRequests, 1); XCTAssertEqual(vault.saves, 2)
        clock.nowEpochMilliseconds += 3_590_000; server.now = clock.nowEpochMilliseconds; server.loseRefresh = true
        do { _ = try await account.credential(origin: enrolled.origin, deviceID: enrolled.deviceID); XCTFail("expected reauthorization") } catch { XCTAssertEqual(error as? RemoteHarnessClientFailure, .reauthorize) }
        XCTAssertEqual(server.refreshRequests, 1); XCTAssertNotNil(vault.record?.refreshAttemptID)
        let restored = RemoteHarnessClientAccount(http: server, storage: vault, backend: crypto, clock: clock)
        do { _ = try await restored.credential(origin: enrolled.origin, deviceID: enrolled.deviceID); XCTFail("must not replay") } catch { XCTAssertEqual(error as? RemoteHarnessClientFailure, .reauthorize) }
        XCTAssertEqual(server.refreshRequests, 1); XCTAssertEqual(vault.record?.privateSeed, enrolled.privateSeed)
    }
    func testRotatedPairCommitFailureRequiresReauthorization() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        let account = RemoteHarnessClientAccount(http: server, storage: vault, backend: crypto, clock: clock, randomSeed: { Data(repeating: 1, count: 32) })
        let old = try await account.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        clock.nowEpochMilliseconds += 3_590_000; server.now = clock.nowEpochMilliseconds; vault.failAtSave = vault.saves + 2
        do { _ = try await account.credential(origin: old.origin, deviceID: old.deviceID); XCTFail("expected reauthorization") } catch { XCTAssertEqual(error as? RemoteHarnessClientFailure, .reauthorize) }
        XCTAssertNotNil(vault.record?.refreshAttemptID); XCTAssertEqual(vault.record?.refreshToken, old.refreshToken)
        do { _ = try await account.credential(origin: old.origin, deviceID: old.deviceID); XCTFail("must not replay") } catch {}
        XCTAssertEqual(server.refreshRequests, 1)
    }
    #if canImport(Combine) && canImport(CryptoKit)
    func testFoundationPromptTimeZoneNormalizationPreservesStrictCarrierValidation() throws {
        let gmt = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(RemoteHarnessClientController.promptTimeZoneIdentifier(gmt.identifier), "UTC")
        XCTAssertEqual(RemoteHarnessClientController.promptTimeZoneIdentifier("UTC"), "UTC")
        XCTAssertEqual(RemoteHarnessClientController.promptTimeZoneIdentifier("Asia/Ulaanbaatar"), "Asia/Ulaanbaatar")
        XCTAssertEqual(RemoteHarnessClientController.promptTimeZoneIdentifier("America/Argentina/Buenos_Aires"), "America/Argentina/Buenos_Aires")
        XCTAssertNil(RemoteHarnessClientController.promptTimeZoneIdentifier("GMT+0800"))
        XCTAssertNil(RemoteHarnessClientController.promptTimeZoneIdentifier("EST"))
        XCTAssertThrowsError(try RemoteHarnessOperation.prompt(commandID: "fixture", sessionID: "fixture", text: "Synthetic", clientTimeZone: "GMT"))
        XCTAssertNoThrow(try RemoteHarnessOperation.prompt(commandID: "fixture", sessionID: "fixture", text: "Synthetic", clientTimeZone: RemoteHarnessClientController.promptTimeZoneIdentifier(gmt.identifier)))
    }
    private func settle(_ predicate: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if predicate() { return }; await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    private func botController(_ server: JourneyServer, storage: JourneyStorage, clock: JourneyClock? = nil) async throws -> RemoteHarnessClientController {
        let vault = JourneyCredentials(); server.credentials = vault
        let native = RemoteHarnessClientController(backend: JourneyCrypto(), http: server, credentials: vault, storage: storage, clock: clock ?? JourneyClock(),
            makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost()
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first))
        XCTAssertEqual(native.screen, .sessions); XCTAssertNil(native.failure)
        return native
    }
    func testBotReadRequiresBothCapabilitiesAndNeverRequestsDuringDiscovery() async throws {
        for capabilities in [[], ["plugin.route.v1"], ["quenderin.bot.read.v1"]] {
            let server = JourneyServer(); server.botCapabilities = capabilities
            let native = try await botController(server, storage: JourneyStorage())
            await native.refreshBots()
            XCTAssertEqual(server.botReads, 0); XCTAssertFalse(native.botReadAvailable); XCTAssertNil(native.botRoster)
            await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
            await native.refreshBots(); XCTAssertEqual(server.botReads, 0); XCTAssertNil(native.failure)
            native.disconnect()
        }
        let server = JourneyServer(), vault = JourneyCredentials(); server.credentials = vault
        server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        let native = RemoteHarnessClientController(backend: JourneyCrypto(), http: server, credentials: vault, storage: JourneyStorage(), clock: JourneyClock(), makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
        defer { native.disconnect() }
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost(); await native.refreshBots()
        XCTAssertEqual(native.screen, .workspaces); XCTAssertEqual(server.botReads, 0); XCTAssertFalse(native.botReadAvailable)
    }
    func testBotReadHasIndependentLoadingExplicitRefreshAndNoPersistence() async throws {
        let server = JourneyServer(), storage = JourneyStorage(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]; server.deferBotReads = true
        let native = try await botController(server, storage: storage); defer { native.disconnect() }
        await settle { server.botReads == 1 && native.botLoading }
        XCTAssertFalse(native.busy); XCTAssertTrue(native.botReadAvailable); XCTAssertNil(native.botRoster)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let saved = try encoder.encode(try XCTUnwrap(storage.value))
        let socket = try XCTUnwrap(server.sockets.last); try socket.replyBotReads()
        await settle { native.botRoster?.revision == 7 && !native.botLoading }
        let bot = try XCTUnwrap(native.botRoster?.bots.first)
        XCTAssertEqual(bot.name, "Synthetic researcher"); XCTAssertTrue(native.canOpenBot(bot)); XCTAssertFalse(native.botUnavailable)
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(storage.value)), saved, "Bot data never enters the journal")
        server.deferBotReads = false; server.botResponseOverride = server.botResponse(revision: 8, bots: [])
        await native.refreshBots()
        XCTAssertEqual(server.botReads, 2); XCTAssertEqual(native.botRoster?.revision, 8); XCTAssertTrue(native.botRoster?.bots.isEmpty == true)
        XCTAssertFalse(native.canOpenBot(bot)); XCTAssertEqual(try encoder.encode(try XCTUnwrap(storage.value)), saved)
        let restored = RemoteHarnessClientController(backend: JourneyCrypto(), storage: storage)
        XCTAssertNil(restored.botRoster); XCTAssertFalse(restored.botReadAvailable); XCTAssertFalse(restored.botLoading)
    }
    func testFailedBotReadPreservesDraftHistoryApprovalAndStop() async throws {
        let server = JourneyServer(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        server.botResponseOverride = server.botResponse(bots: [])
        let native = try await botController(server, storage: JourneyStorage()); defer { native.disconnect() }
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady && native.botRoster != nil }
        native.updateDraft("Synthetic remote task"); await native.send(); await settle { native.approvalCards.first?.action != nil }
        native.updateDraft("Keep this unfinished draft")
        let history = native.timeline.records, approvals = native.approvals.map(\.eventID), commands = native.journal.commands.count
        let action = native.approvalCards.first?.action?.arguments
        server.deferBotReads = true
        let refresh = Task { await native.refreshBots() }
        await settle { native.botLoading && server.sockets.last?.pendingBotReads.count == 1 }
        XCTAssertTrue(native.canStop); XCTAssertFalse(native.busy)
        try XCTUnwrap(server.sockets.last).replyBotReads(["status": 503, "json": ["ok": false, "error": "Synthetic private Host diagnostic"]])
        await refresh.value
        XCTAssertTrue(native.botUnavailable); XCTAssertNil(native.botRoster); XCTAssertNil(native.failure)
        XCTAssertEqual(native.journal.draft, "Keep this unfinished draft"); XCTAssertEqual(native.timeline.records, history)
        XCTAssertEqual(native.approvals.map(\.eventID), approvals); XCTAssertEqual(native.approvalCards.first?.action?.arguments, action)
        XCTAssertEqual(native.journal.commands.count, commands); XCTAssertTrue(native.canStop)
        await native.stop(); XCTAssertEqual(server.cancellations, 1); XCTAssertEqual(native.stopState, .receiptReceived)
    }
    func testBotReadDeadlineStaysLocalAndSessionRemainsUsable() async throws {
        let server = JourneyServer(), clock = JourneyClock(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        server.botResponseOverride = server.botResponse(bots: []); server.running = true; server.snapshotActiveAttempt = true
        let native = try await botController(server, storage: JourneyStorage(), clock: clock); defer { native.disconnect() }
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady && native.botRoster != nil }
        // Snapshot delivery precedes its stream.open acknowledgement. Complete
        // an RPC round trip before advancing time so earlier opens are settled.
        await native.refreshSessionState(); XCTAssertNil(native.failure)
        native.updateDraft("Keep this unfinished draft")
        let history = native.timeline.records, commands = native.journal.commands.count, sockets = server.sockets.count
        let socket = try XCTUnwrap(server.sockets.last)
        server.deferBotReads = true
        let refresh = Task { await native.refreshBots() }
        await settle { native.botLoading && socket.pendingBotReads.count == 1 }
        let reads = server.botReads
        clock.monotonicMilliseconds += 60_000
        try socket.frame("$events", ["type": "keepalive"])
        // A dequeued packet count is not proof the keepalive was processed.
        // The following response is queued after it on this same connection.
        await native.refreshSessionState(); XCTAssertNil(native.failure)
        clock.monotonicMilliseconds += RemoteHarnessLimits.deadlineMilliseconds - 60_000
        // An authenticated live frame drives expiry and refreshes transport
        // liveness; this exercises RPC expiry independently of heartbeat loss.
        try socket.frame("$events", ["type": "keepalive"])
        await refresh.value
        XCTAssertTrue(native.botUnavailable); XCTAssertFalse(native.botLoading); XCTAssertNil(native.botRoster)
        XCTAssertNil(native.failure); XCTAssertEqual(native.screen, .session); XCTAssertTrue(native.snapshotReady)
        XCTAssertTrue(native.botReadAvailable); XCTAssertTrue(native.canStop); XCTAssertFalse(socket.closed)
        XCTAssertEqual(server.sockets.count, sockets); XCTAssertEqual(native.journal.commands.count, commands)
        XCTAssertEqual(native.journal.draft, "Keep this unfinished draft"); XCTAssertEqual(native.timeline.records, history)
        try socket.replyBotReads(server.botResponse(revision: 99))
        await native.refreshSessionState()
        XCTAssertNil(native.botRoster); XCTAssertTrue(native.botUnavailable)
        await native.stop()
        XCTAssertEqual(server.cancellations, 1); XCTAssertEqual(native.stopState, .receiptReceived)
        XCTAssertNil(native.failure); XCTAssertFalse(socket.closed); XCTAssertEqual(native.screen, .session)
        XCTAssertNil(native.botRoster); XCTAssertTrue(native.botUnavailable); XCTAssertEqual(server.botReads, reads)
    }
    func testBotReadRejectsWrongWorkspaceWithoutChangingSessionState() async throws {
        let server = JourneyServer(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        server.botResponseOverride = server.botResponse(workspaceID: "workspace-other")
        let native = try await botController(server, storage: JourneyStorage()); defer { native.disconnect() }
        await settle { native.botUnavailable }
        XCTAssertNil(native.botRoster); XCTAssertNil(native.failure); XCTAssertEqual(native.screen, .sessions)
        server.botResponseOverride = server.botResponse()
        await native.refreshBots()
        let bot = try XCTUnwrap(native.botRoster?.bots.first)
        await native.openBotSession(bot); await settle { native.snapshotReady }
        XCTAssertEqual(native.journal.sessionID, "session-real"); XCTAssertEqual(server.creations, 0); XCTAssertEqual(server.prompts, 0)
    }
    func testBotGenerationRetirementClearsImmediatelyAndReconnectRefetches() async throws {
        let server = JourneyServer(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        let native = try await botController(server, storage: JourneyStorage()); defer { native.disconnect() }
        await settle { native.botRoster != nil }
        let oldBot = try XCTUnwrap(native.botRoster?.bots.first), oldSocket = try XCTUnwrap(server.sockets.last)
        server.deferBotReads = true
        let oldRefresh = Task { await native.refreshBots() }; await settle { oldSocket.pendingBotReads.count == 1 }
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady && server.sockets.last?.pendingBotReads.count == 1 }
        XCTAssertNil(native.botRoster); XCTAssertFalse(native.canOpenBot(oldBot)); XCTAssertTrue(native.botLoading)
        try oldSocket.replyBotReads(server.botResponse(revision: 99)); await oldRefresh.value
        XCTAssertNil(native.botRoster, "retired generation cannot publish its result")
        try XCTUnwrap(server.sockets.last).replyBotReads(server.botResponse(revision: 8)); await settle { native.botRoster?.revision == 8 }
        let reads = server.botReads
        native.disconnect()
        XCTAssertNil(native.botRoster); XCTAssertFalse(native.botReadAvailable); XCTAssertFalse(native.botLoading); XCTAssertFalse(native.canOpenBot(oldBot))
        server.deferBotReads = false; server.botResponseOverride = server.botResponse(revision: 9)
        await native.reconnect(); await settle { native.snapshotReady && native.botRoster?.revision == 9 }
        XCTAssertEqual(server.botReads, reads + 1); XCTAssertNil(native.failure)
    }
    func testBotNavigationRequiresCurrentUniqueSessionAndLiveWorkspaceMembership() async throws {
        let server = JourneyServer(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        let native = try await botController(server, storage: JourneyStorage()); defer { native.disconnect() }
        await settle { native.botRoster != nil }
        let bot = try XCTUnwrap(native.botRoster?.bots.first), socket = try XCTUnwrap(server.sockets.last)
        server.workspaceSessionIDs = []
        try socket.frame("workspace/follow", ["type": "upsert", "workspace": server.workspace])
        await settle { native.workspaces.first?.sessionIDs.isEmpty == true }
        let sockets = server.sockets.count
        XCTAssertFalse(native.canOpenBot(bot)); await native.openBotSession(bot)
        XCTAssertEqual(server.sockets.count, sockets); XCTAssertNil(native.journal.sessionID)
        server.workspaceSessionIDs = ["session-real"]; server.sessionRowsOverride = [server.sessionRow, server.sessionRow]
        try socket.frame("workspace/follow", ["type": "upsert", "workspace": server.workspace])
        await settle { native.workspaces.first?.sessionIDs == ["session-real"] }
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first)); await settle { native.botRoster != nil }
        XCTAssertEqual(native.sessions.count, 2); XCTAssertFalse(native.canOpenBot(bot))
        let duplicateSockets = server.sockets.count; await native.openBotSession(bot)
        XCTAssertEqual(server.sockets.count, duplicateSockets); XCTAssertNil(native.journal.sessionID)
    }
    func testBotNavigationUsesExactUTF8SessionIdentity() async throws {
        let server = JourneyServer(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        let composed = "session-\u{e9}", decomposed = "session-e\u{301}"
        var row = server.sessionRow; row["sessionId"] = composed
        server.workspaceSessionIDs = [composed]; server.sessionRowsOverride = [row]
        server.botResponseOverride = server.botResponse(bots: [["id": "bot-real", "name": "Synthetic researcher", "sessionId": decomposed, "model": NSNull(), "permission": NSNull()]])
        let native = try await botController(server, storage: JourneyStorage()); defer { native.disconnect() }
        await settle { native.botRoster != nil }
        let bot = try XCTUnwrap(native.botRoster?.bots.first), sockets = server.sockets.count
        XCTAssertFalse(native.canOpenBot(bot)); await native.openBotSession(bot)
        XCTAssertEqual(server.sockets.count, sockets); XCTAssertNil(native.journal.sessionID); XCTAssertEqual(server.creations, 0)
    }
    func testBotSessionReadOnlyMarkerSurvivesOrdinaryReselectColdRestoreAndReconnect() async throws {
        let server = JourneyServer(), storage = JourneyStorage(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        let native = try await botController(server, storage: storage)
        await settle { native.botRoster != nil }
        await native.openBotSession(try XCTUnwrap(native.botRoster?.bots.first)); await settle { native.snapshotReady }
        native.updateDraft("Preserve this Bot draft")
        XCTAssertTrue(native.isBotSessionReadOnly); XCTAssertFalse(native.canSend); XCTAssertFalse(native.canChangeModel)
        let commands = native.journal.commands.count
        await native.send(); await native.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(server.modelSelections, 0); XCTAssertEqual(native.journal.commands.count, commands)
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        XCTAssertTrue(native.isBotSessionReadOnly); XCTAssertEqual(native.journal.draft, "Preserve this Bot draft")
        native.disconnect(); server.botCapabilities = []
        let restored = RemoteHarnessClientController(backend: JourneyCrypto(), http: server, credentials: try XCTUnwrap(server.credentials), storage: storage, clock: JourneyClock(), makeSocket: { server.makeSocket() })
        defer { restored.disconnect() }
        XCTAssertTrue(restored.isBotSessionReadOnly); XCTAssertNil(restored.botRoster)
        await restored.reconnect(); await settle { restored.snapshotReady }
        XCTAssertTrue(restored.isBotSessionReadOnly); XCTAssertFalse(restored.botReadAvailable)
        await restored.send(); await restored.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(server.modelSelections, 0); XCTAssertEqual(restored.journal.commands.count, commands)
        await restored.selectWorkspace(try XCTUnwrap(restored.workspaces.first)); await restored.createSession(); await settle { restored.snapshotReady }
        XCTAssertEqual(restored.journal.sessionID, "session-created"); XCTAssertFalse(restored.isBotSessionReadOnly)
        restored.updateDraft("A separate normal task"); XCTAssertTrue(restored.canSend); XCTAssertTrue(restored.canChangeModel)
        await restored.selectModel("synthetic:deepseek-harness", effort: "high"); XCTAssertEqual(server.modelSelections, 1)
    }
    func testBotClassificationBlocksMutationsUntilCurrentRosterAndMarksOrdinarySelection() async throws {
        let server = JourneyServer(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]; server.deferBotReads = true
        let native = try await botController(server, storage: JourneyStorage()); defer { native.disconnect() }
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady && server.sockets.last?.pendingBotReads.count == 1 }
        native.updateDraft("Wait for ownership verification")
        let commands = native.journal.commands.count
        XCTAssertTrue(native.botSessionClassificationPending); XCTAssertFalse(native.isBotSessionReadOnly); XCTAssertFalse(native.canSend); XCTAssertFalse(native.canChangeModel)
        await native.send(); await native.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(server.modelSelections, 0); XCTAssertEqual(native.journal.commands.count, commands)
        try XCTUnwrap(server.sockets.last).replyBotReads(server.botResponse(bots: [])); await settle { !native.botLoading }
        XCTAssertFalse(native.botSessionClassificationPending); XCTAssertFalse(native.isBotSessionReadOnly); XCTAssertTrue(native.canSend); XCTAssertTrue(native.canChangeModel)
        let refresh = Task { await native.refreshBots() }; await settle { native.botLoading }
        XCTAssertFalse(native.canSend); XCTAssertFalse(native.canChangeModel)
        try XCTUnwrap(server.sockets.last).replyBotReads(); await refresh.value
        XCTAssertTrue(native.isBotSessionReadOnly); XCTAssertFalse(native.canSend); XCTAssertFalse(native.canChangeModel)
        await native.send(); await native.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(server.modelSelections, 0); XCTAssertEqual(native.journal.commands.count, commands)
    }
    func testFailedBotMarkerSavePreservesPreviousRecordAndBlocksMutations() async throws {
        let server = JourneyServer(), storage = JourneyStorage(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]; server.deferBotReads = true
        let native = try await botController(server, storage: storage); defer { native.disconnect() }
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady && server.sockets.last?.pendingBotReads.count == 1 }
        native.updateDraft("Keep the previous protected record")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let previous = try encoder.encode(try XCTUnwrap(storage.value)), commands = native.journal.commands.count
        storage.failWrites = true
        try XCTUnwrap(server.sockets.last).replyBotReads(); await settle { native.botUnavailable }
        XCTAssertEqual(native.failure, .storage); XCTAssertTrue(native.botSessionClassificationPending)
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(storage.value)), previous); XCTAssertEqual(native.journal.draft, "Keep the previous protected record")
        await native.send(); await native.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(server.modelSelections, 0); XCTAssertEqual(native.journal.commands.count, commands)
    }
    func testLegacyBotMarkerDecodeAndExactScopeValidation() async throws {
        let server = JourneyServer(), storage = JourneyStorage(); server.botCapabilities = ["plugin.route.v1", "quenderin.bot.read.v1"]
        let native = try await botController(server, storage: storage); defer { native.disconnect() }
        await settle { native.botRoster != nil }
        await native.openBotSession(try XCTUnwrap(native.botRoster?.bots.first)); await settle { native.snapshotReady }
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        let saved = try XCTUnwrap(storage.value), scope = try XCTUnwrap(saved.botReadOnlyScope)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacy.removeValue(forKey: "botReadOnlyScope")
        var sessions = try XCTUnwrap(legacy["savedSessions"] as? [[String: Any]])
        for index in sessions.indices { sessions[index].removeValue(forKey: "botReadOnlyScope") }; legacy["savedSessions"] = sessions
        let decoded = try JSONDecoder().decode(RemoteHarnessClientJournal.self, from: JSONSerialization.data(withJSONObject: legacy))
        try decoded.validate(); XCTAssertNil(decoded.botReadOnlyScope); XCTAssertTrue(decoded.savedSessions.allSatisfy { $0.botReadOnlyScope == nil })
        XCTAssertTrue(scope.matches(origin: saved.origin, hostID: saved.profile?.hostID, hostFingerprint: saved.profile?.hostFingerprint, workspaceID: saved.profile?.workspaceID, sessionID: saved.sessionID))
        XCTAssertFalse(scope.matches(origin: "https://other.example", hostID: scope.hostID, hostFingerprint: scope.hostFingerprint, workspaceID: scope.workspaceID, sessionID: scope.sessionID))
        XCTAssertFalse(scope.matches(origin: scope.origin, hostID: scope.hostID, hostFingerprint: "changed-pin", workspaceID: scope.workspaceID, sessionID: scope.sessionID))
        let unicode = RemoteHarnessClientBotSessionScope(origin: scope.origin, hostID: scope.hostID, hostFingerprint: scope.hostFingerprint, workspaceID: "workspace-\u{e9}", sessionID: "session-\u{e9}")
        XCTAssertFalse(unicode.matches(origin: scope.origin, hostID: scope.hostID, hostFingerprint: scope.hostFingerprint, workspaceID: "workspace-e\u{301}", sessionID: "session-e\u{301}"))
        var invalid = saved; invalid.sessionID = "different-session"; XCTAssertThrowsError(try invalid.validate())
    }
    func testOfficialRuntimeFactsReplayThroughNativeControllerToReady() async throws {
        let official = try JourneyOfficialRuntime()
        let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock()
        server.credentials = vault; server.official = official
        // Rebind only the enclosing transport clock, retaining the captured
        // approval expiry and event timestamps. This gives the action 60s TTL.
        server.now = official.hostTimestamp; clock.nowEpochMilliseconds = official.hostTimestamp
        let native = RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock,
            makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
        defer { native.disconnect() }
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost()
        await settle { native.workspaces.first?.sessionIDs == ["fixture-session"] }
        XCTAssertNil(native.failure)
        let workspace = try XCTUnwrap(native.workspaces.first)
        XCTAssertEqual(workspace.workspaceID, "fixture-workspace"); XCTAssertEqual(workspace.path, "<fixture-root>/workspace")
        await native.selectWorkspace(workspace)
        XCTAssertEqual(native.sessions.map(\.sessionID), ["fixture-session"])
        XCTAssertEqual(native.sessions.first?.title, "Untitled session"); XCTAssertEqual(native.sessions.first?.running, false)
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        XCTAssertNil(native.failure); XCTAssertEqual(native.timeline.cursor, -1); XCTAssertTrue(native.timeline.records.isEmpty)
        let socket = try XCTUnwrap(server.sockets.last)
        await settle { socket.emittedOfficialFrames == Array(0..<7) }
        native.updateDraft("Run the synthetic fixture tool once."); XCTAssertTrue(native.canSend)
        await native.send(); await settle { native.approvals.count == 1 }
        XCTAssertNil(native.failure); XCTAssertEqual(server.prompts, 1); XCTAssertEqual(native.journal.draft, "")
        XCTAssertEqual(native.journal.commands.filter { $0.endpoint == "session/prompt" }.map(\.outcome), ["responseReceived"])
        XCTAssertEqual(native.selectedModelID, "fixture:scripted", "actual sequenced control projection reaches the controller")
        XCTAssertEqual(socket.emittedOfficialFrames, Array(0..<23))
        let approval = try XCTUnwrap(native.approvals.first)
        XCTAssertEqual(approval.eventID, "fixture-event"); XCTAssertEqual(approval.clientID, "fixture-event-client")
        let binding = try XCTUnwrap(approval.extensionBinding)
        XCTAssertEqual(binding.expiresAt - approval.hostTimestamp, 60_000)
        XCTAssertNil(native.approvalAction(for: approval)); XCTAssertNil(native.approvalCards.first?.action)
        XCTAssertTrue(native.canStop, "Stop stays available while approval metadata has no call arguments")
        let journalBefore = native.journal.commands
        await native.decide(approval, allow: true); await native.decide(approval, allow: false)
        XCTAssertEqual(server.approvals, 0); XCTAssertEqual(native.journal.commands.count, journalBefore.count)
        XCTAssertNil(native.failure); XCTAssertTrue(native.canStop); XCTAssertEqual(native.screen, .session)
        XCTAssertEqual(socket.emittedOfficialFrames, Array(0..<23), "neither forced decision dispatches")
        socket.officialFrameLimit = 27; try socket.drainOfficialFrames()
        await settle { native.timeline.rows.contains { $0.kind == "tool" } }
        XCTAssertNil(native.approvalAction(for: approval), "a transient argument chunk is not durable execution evidence")
        socket.officialFrameLimit = 33; try socket.drainOfficialFrames()
        await settle { native.approvalCards.first?.action != nil }
        XCTAssertEqual(native.approvals.first, approval, "the same pending approval resolves when history arrives")
        XCTAssertEqual(native.approvalCards.first?.action?.arguments, "{\"text\":\"synthetic action\"}")
        XCTAssertEqual(native.approvalCards.first?.action?.callID, "fixture-call-1")
        XCTAssertEqual(native.approvalCards.first?.action?.toolName, "fixture_echo")
        XCTAssertTrue(server.sockets.last === socket, "evidence arrival and approval keep the same live connection")
        await native.decide(approval, allow: true)
        await settle { native.timeline.records.count == 19 && !native.running }
        XCTAssertNil(native.failure); XCTAssertEqual(server.approvals, 1)
        XCTAssertEqual(native.journal.commands.filter { $0.endpoint == "quenderin/approval" }.map(\.outcome), ["responseReceived"])
        XCTAssertEqual(socket.emittedOfficialFrames, Array(0..<official.frames.count), "all captured business frames retain global order")
        XCTAssertTrue(native.timeline.rows.contains { $0.kind == "user" && $0.text == "Run the synthetic fixture tool once." })
        XCTAssertTrue(native.timeline.rows.contains { $0.kind == "tool" && $0.text == "synthetic result" })
        XCTAssertEqual(native.timeline.rows.filter { $0.kind == "assistant" && $0.text == "Synthetic tool completed." }.count, 1)
        XCTAssertTrue(native.approvals.isEmpty); XCTAssertTrue(native.snapshotReady); XCTAssertEqual(native.screen, .session)
        XCTAssertFalse(native.running); XCTAssertFalse(native.canStop); XCTAssertEqual(native.stopState, .notRequested, "normal completion is READY, never a Stop confirmation")
        native.updateDraft("Next synthetic task"); XCTAssertTrue(native.canSend)
        XCTAssertEqual(storage.value?.history, native.timeline.records, "actual durable history is checkpointed")
    }
    func testNativeControllerSetupTrustStreamApprovalStopAndExactRecovery() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        let gmt = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func controller() -> RemoteHarnessClientController { RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock, makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) }, clientTimeZone: { gmt }) }
        let native = controller()
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        XCTAssertEqual(native.screen, .computers); XCTAssertEqual(native.hosts.count, 1); XCTAssertNil(native.journal.profile)
        await native.selectHost(try XCTUnwrap(native.hosts.first)); XCTAssertEqual(native.screen, .trust)
        XCTAssertEqual(native.pendingFingerprint?.count, 64); XCTAssertTrue(server.sockets.isEmpty)
        await native.trustHost(); await settle { native.screen == .workspaces }
        XCTAssertEqual(native.workspaces.map(\.workspaceID), ["workspace-real"])
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first)); XCTAssertEqual(native.screen, .sessions)
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        XCTAssertEqual(native.journal.sessionID, "session-real"); XCTAssertEqual(native.timeline.rows.first?.text, "Synthetic earlier task")
        await native.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertNil(native.failure); XCTAssertFalse(native.running); XCTAssertFalse(native.busy); XCTAssertTrue(native.companionAvailable)
        server.now += 5_000 // Host wall-clock skew must not block a fresh approval.
        native.updateDraft("Synthetic remote task"); XCTAssertTrue(native.canSend)
        await native.send(); XCTAssertNil(native.failure); await settle { !native.approvals.isEmpty }
        XCTAssertEqual(server.prompts, 1); XCTAssertEqual(native.journal.draft, "")
        XCTAssertEqual(server.lastPromptTimeZone, "UTC")
        XCTAssertTrue(native.timeline.rows.contains { $0.text == "Synthetic streamed answer" }); XCTAssertTrue(native.timeline.rows.contains { $0.kind == "reasoning" })
        let approval = try XCTUnwrap(native.approvals.first); XCTAssertNotNil(approval.extensionBinding)
        XCTAssertEqual(native.approvalCards.first?.action?.arguments, "{}", "history-first arrival resolves when approval metadata follows")
        let socket = try XCTUnwrap(server.sockets.last)
        // A replacement outside this session still invalidates the old action.
        try socket.frame("$events", ["type": "waterfall", "event": "approval/request", "eventId": approval.eventID, "agentId": "another-session", "request": ["toolName": "changed_action"]])
        await settle { native.approvals.isEmpty }
        await native.decide(approval, allow: true); XCTAssertEqual(server.approvals, 0)
        let request = ["toolName": "read_file", "callId": "synthetic-call", "reason": "Synthetic tool"]
        func approvalFrame(_ id: String, digest: String) throws -> [String: Any] {
            ["type": "waterfall", "event": "approval/request", "eventId": id, "agentId": "session-real", "request": request,
             "quenderinBinding": ["hostDeviceId": server.hostID, "clientDeviceId": server.deviceID, "workspaceId": "workspace-real", "sessionId": "session-real", "runId": "turn:1", "eventId": id, "actionDigest": digest, "expiresAt": server.now + 60_000]]
        }
        try socket.frame("$events", approvalFrame("wrong-digest", digest: String(repeating: "a", count: 64)))
        await settle { native.approvals.contains { $0.eventID == "wrong-digest" } }
        let mismatched = try XCTUnwrap(native.approvals.first { $0.eventID == "wrong-digest" })
        XCTAssertNil(mismatched.extensionBinding); await native.decide(mismatched, allow: true); XCTAssertEqual(server.approvals, 0)
        let digest = try RemoteHarnessApprovalDigest.digest(journeyJSON(request))
        try socket.frame("$events", approvalFrame("fresh-action", digest: digest))
        await settle { native.approvals.contains { $0.eventID == "fresh-action" } }
        let fresh = try XCTUnwrap(native.approvals.first { $0.eventID == "fresh-action" })
        await native.decide(fresh, allow: true); XCTAssertEqual(server.approvals, 1)
        await native.decide(fresh, allow: true); XCTAssertEqual(server.approvals, 1, "exact approval cannot replay")
        try socket.frame("$events", approvalFrame("expiring-action", digest: digest))
        await settle { native.approvals.contains { $0.eventID == "expiring-action" } }
        let expiring = try XCTUnwrap(native.approvals.first { $0.eventID == "expiring-action" })
        clock.monotonicMilliseconds += 60_000
        await native.decide(expiring, allow: true); XCTAssertEqual(server.approvals, 1, "client monotonic expiry rejects an old action")
        await native.stop(); XCTAssertEqual(native.stopState, .receiptReceived, "receipt alone cannot claim stopped")
        server.running = false; await native.refreshSessionState(); XCTAssertEqual(native.stopState, .confirmedStopped)
        native.updateDraft("Retained unfinished draft"); native.disconnect()
        let recovered = controller(); XCTAssertEqual(recovered.screen, .disconnected); XCTAssertEqual(recovered.journal.draft, "Retained unfinished draft")
        await recovered.reconnect(); await settle { recovered.snapshotReady }
        XCTAssertEqual(recovered.journal.sessionID, "session-real"); XCTAssertEqual(server.prompts, 1)
        XCTAssertEqual(recovered.journal.draft, "Retained unfinished draft")
        await recovered.selectWorkspace(try XCTUnwrap(recovered.workspaces.first)); await recovered.createSession(); await settle { recovered.snapshotReady }
        XCTAssertEqual(recovered.journal.sessionID, "session-created"); XCTAssertEqual(server.prompts, 1)
        XCTAssertTrue(recovered.journal.savedSessions.contains { $0.sessionID == "session-real" && $0.draft == "Retained unfinished draft" }); recovered.disconnect()
    }
    func testConflictingCallAndTurnClosureInvalidateStaleApprovalBeforeJournalOrDispatch() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        let native = RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock, makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
        defer { native.disconnect() }
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost()
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first)); await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        native.updateDraft("Synthetic remote task"); await native.send(); await settle { native.approvalCards.first?.action != nil }
        let stale = try XCTUnwrap(native.approvals.first), socket = try XCTUnwrap(server.sockets.last)
        let before = native.journal.commands.count
        try socket.frame("session/follow", ["type": "event", "event": ["type": "tool/call", "seq": 4, "time": server.now,
            "data": ["turn": 1, "callId": "synthetic-call", "name": "read_file", "arguments": "{\"changed\":true}"]]])
        await settle { native.approvalCards.first?.action == nil }
        XCTAssertTrue(native.snapshotReady); XCTAssertEqual(native.screen, .session); XCTAssertTrue(native.canStop)
        await native.decide(stale, allow: true); await native.decide(stale, allow: false)
        XCTAssertEqual(server.approvals, 0); XCTAssertEqual(native.journal.commands.count, before)
        try socket.frame("session/follow", ["type": "event", "event": ["type": "turn/start", "seq": 5, "time": server.now, "data": ["turn": 1]]])
        try socket.frame("session/follow", ["type": "event", "event": ["type": "tool/call", "seq": 6, "time": server.now,
            "data": ["turn": 1, "callId": "synthetic-call", "name": "read_file", "arguments": "{}"]]])
        let request = ["toolName": "read_file", "callId": "synthetic-call", "reason": "Synthetic tool"]
        try socket.frame("$events", ["type": "waterfall", "event": "approval/request", "eventId": "fresh-after-repeat", "agentId": "session-real", "request": request,
            "quenderinBinding": ["hostDeviceId": server.hostID, "clientDeviceId": server.deviceID, "workspaceId": "workspace-real", "sessionId": "session-real", "runId": "turn:1", "eventId": "fresh-after-repeat",
                                  "actionDigest": try RemoteHarnessApprovalDigest.digest(journeyJSON(request)), "expiresAt": server.now + 60_000]])
        await settle { native.approvals.first?.eventID == "fresh-after-repeat" }
        let fresh = try XCTUnwrap(native.approvals.first)
        XCTAssertNotNil(fresh.extensionBinding); XCTAssertNil(native.approvalCards.first?.action)
        await native.decide(fresh, allow: true); await native.decide(fresh, allow: false)
        XCTAssertEqual(server.approvals, 0); XCTAssertEqual(native.journal.commands.count, before); XCTAssertTrue(native.canStop)
        try socket.frame("session/follow", ["type": "event", "event": ["type": "turn/end", "seq": 7, "time": server.now, "data": ["turn": 1]]])
        await settle { native.approvals.isEmpty }
        await native.decide(stale, allow: true)
        XCTAssertEqual(server.approvals, 0); XCTAssertEqual(native.journal.commands.count, before)
        XCTAssertFalse(native.running); XCTAssertNil(native.approvalAction(for: stale))
        native.disconnect(); XCTAssertTrue(native.approvalCards.isEmpty); XCTAssertFalse(native.timeline.hasActiveTurn)
    }
    func testChangedSameRunSnapshotCannotAuthorizeFreshBoundApproval() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        let native = RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock, makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
        defer { native.disconnect() }
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost()
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first)); await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        native.updateDraft("Synthetic remote task"); await native.send(); await settle { native.approvalCards.first?.action != nil }
        XCTAssertEqual(native.approvalCards.first?.action?.sequence, 3)
        let socket = try XCTUnwrap(server.sockets.last), before = native.journal.commands.count
        var records = try native.timeline.records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        var call = try XCTUnwrap(records.last?["event"] as? [String: Any]), data = try XCTUnwrap(call["data"] as? [String: Any])
        data["arguments"] = "{\"changed\":true}"; call["data"] = data; records[records.count - 1]["event"] = call
        try socket.frame("session/follow", ["type": "snapshot", "header": ["id": "session-real"], "cursor": 3, "hasMore": false, "records": records])
        let request = ["toolName": "read_file", "callId": "synthetic-call", "reason": "Synthetic tool"]
        try socket.frame("$events", ["type": "waterfall", "event": "approval/request", "eventId": "fresh-after-snapshot", "agentId": "session-real", "request": request,
            "quenderinBinding": ["hostDeviceId": server.hostID, "clientDeviceId": server.deviceID, "workspaceId": "workspace-real", "sessionId": "session-real", "runId": "turn:1", "eventId": "fresh-after-snapshot",
                                  "actionDigest": try RemoteHarnessApprovalDigest.digest(journeyJSON(request)), "expiresAt": server.now + 60_000]])
        await settle { native.approvals.first?.eventID == "fresh-after-snapshot" }
        let fresh = try XCTUnwrap(native.approvals.first)
        XCTAssertNotNil(fresh.extensionBinding); XCTAssertNil(native.approvalCards.first?.action)
        await native.decide(fresh, allow: true); await native.decide(fresh, allow: false)
        XCTAssertEqual(server.approvals, 0); XCTAssertEqual(native.journal.commands.count, before)
        XCTAssertNil(native.failure); XCTAssertTrue(native.snapshotReady); XCTAssertEqual(native.screen, .session); XCTAssertTrue(native.canStop)
        XCTAssertTrue(server.sockets.last === socket)
        XCTAssertEqual(try RemoteHarnessJSON(data: XCTUnwrap(native.timeline.records.last)).fields().required("event").fields().required("data").fields().required("arguments").stringValue(), "{\"changed\":true}")
    }
    func testFailedMutationJournalBlocksDispatchAndKeepsDraft() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        let native = RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock, makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost(); await settle { !native.workspaces.isEmpty }
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first)); await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        native.updateDraft("Do not lose this task"); storage.failWrites = true; await native.send()
        XCTAssertEqual(native.failure, .storage, "the mutation must reach the durable journal gate")
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(native.journal.draft, "Do not lose this task"); native.disconnect()
    }
    func testMissingCompanionBlocksTaskMutationsAndPreservesRecoveryAndStop() async throws {
        let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
        server.companionAvailable = false; server.running = true
        func controller() -> RemoteHarnessClientController { RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock, makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) }) }
        let native = controller()
        await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
        await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost()
        XCTAssertFalse(native.companionAvailable); XCTAssertEqual(native.screen, .workspaces)
        await native.selectWorkspace(try XCTUnwrap(native.workspaces.first))
        XCTAssertFalse(native.canCreateSession); await native.createSession()
        XCTAssertEqual(native.failure, .companionRequired); XCTAssertEqual(server.creations, 0)
        await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
        XCTAssertEqual(native.timeline.rows.first?.text, "Synthetic earlier task")
        native.updateDraft("Retain task until computer is paired")
        XCTAssertFalse(native.canSend); await native.send()
        XCTAssertEqual(native.failure, .companionRequired); XCTAssertEqual(server.prompts, 0)
        XCTAssertFalse(native.canChangeModel); await native.selectModel("synthetic:deepseek-harness", effort: "high")
        XCTAssertEqual(native.failure, .companionRequired); XCTAssertEqual(server.modelSelections, 0)
        XCTAssertTrue(native.journal.commands.isEmpty, "blocked mutations must not enter the dispatch journal")
        XCTAssertEqual(native.journal.draft, "Retain task until computer is paired")
        await native.stop(); XCTAssertEqual(server.cancellations, 1); XCTAssertEqual(native.stopState, .receiptReceived)
        server.running = false; await native.refreshSessionState(); XCTAssertEqual(native.stopState, .confirmedStopped)
        native.disconnect()
        let recovered = controller(); await recovered.reconnect(); await settle { recovered.snapshotReady }
        XCTAssertEqual(recovered.journal.sessionID, "session-real"); XCTAssertEqual(recovered.journal.draft, "Retain task until computer is paired")
        XCTAssertFalse(recovered.companionAvailable); XCTAssertFalse(recovered.canSend)
        XCTAssertEqual(server.prompts, 0); XCTAssertEqual(server.creations, 0); XCTAssertEqual(server.modelSelections, 0); recovered.disconnect()
    }
    func testActiveSnapshotAndTurnHistoryOverrideStaleIdleListAndEnableStop() async throws {
        for activeAttempt in [true, false] {
            let server = JourneyServer(), vault = JourneyCredentials(), storage = JourneyStorage(), crypto = JourneyCrypto(), clock = JourneyClock(); server.credentials = vault
            server.running = false // The list is read before the computer starts.
            server.snapshotActiveAttempt = activeAttempt
            server.snapshotTurnEvent = activeAttempt ? nil : "turn/start"
            let native = RemoteHarnessClientController(backend: crypto, http: server, credentials: vault, storage: storage, clock: clock, makeSocket: { server.makeSocket() }, randomSeed: { Data(repeating: 1, count: 32) })
            await native.authorize(origin: "https://synthetic.example", email: "synthetic@example.test", password: "synthetic-entry", deviceName: "Synthetic client")
            await native.selectHost(try XCTUnwrap(native.hosts.first)); await native.trustHost()
            await native.selectWorkspace(try XCTUnwrap(native.workspaces.first))
            XCTAssertFalse(try XCTUnwrap(native.sessions.first).running)
            await native.selectSession(try XCTUnwrap(native.sessions.first)); await settle { native.snapshotReady }
            XCTAssertTrue(native.running); XCTAssertTrue(native.canStop)
            let socket = try XCTUnwrap(server.sockets.last)
            if activeAttempt {
                let before = socket.receivedCount
                try socket.frame("session/follow", ["type": "assistant-stream", "frame": ["type": "end", "attemptId": "snapshot-active", "revision": 6, "index": 1]])
                await settle { socket.receivedCount > before }
                XCTAssertTrue(native.running, "assistant attempt end may leave tools running")
                XCTAssertTrue(native.canStop)
            }
            server.running = true // Subsequent authoritative list reflects the active turn.
            await native.stop(); XCTAssertEqual(server.cancellations, 1); XCTAssertEqual(native.stopState, .receiptReceived)
            let endSequence = activeAttempt ? 2 : 3
            try socket.frame("session/follow", ["type": "event", "event": ["type": "turn/end", "seq": endSequence, "time": server.now, "data": ["turn": 1]]])
            await settle { !native.running }
            XCTAssertFalse(native.canStop); XCTAssertEqual(native.stopState, .confirmedStopped)
            if !activeAttempt {
                try socket.frame("session/follow", ["type": "assistant-stream", "frame": ["type": "start", "attemptId": "next-attempt", "revision": 1, "startedAfterSeq": endSequence, "turn": 2, "step": 0]])
                await settle { native.running }
                XCTAssertTrue(native.canStop, "a validated assistant start enables Stop before the next list refresh")
            }
            native.disconnect()
        }
    }
    #endif
}
