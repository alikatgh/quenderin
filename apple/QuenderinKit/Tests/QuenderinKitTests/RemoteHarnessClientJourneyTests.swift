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
    var workspace: [String: Any] { ["workspaceId": "workspace-real", "path": "/synthetic/project", "title": "Synthetic workspace", "sessionIds": created ? ["session-real", "session-created"] : ["session-real"], "createdAt": "2026-10-23", "updatedAt": "2026-10-23"] }
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
                let capabilities = server.companionAvailable ? ["harness.remote.v3", "quenderin.approvals.v1"] : ["harness.remote.v3"]
                try business("rpc.response", ["requestId": rpcID, "result": ["capabilities": capabilities]]); return
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
                    server.prompts += 1; officialFrameLimit = 33
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
            case "session/list": value = ["items": server.created ? [server.sessionRow, ["sessionId": "session-created", "updatedAt": server.now, "running": false, "blank": true, "title": "New synthetic session"]] : [server.sessionRow]]
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
                let request = ["toolName": "read_file", "reason": "Synthetic tool"]
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
        XCTAssertEqual(socket.emittedOfficialFrames, Array(0..<33))
        let approval = try XCTUnwrap(native.approvals.first)
        XCTAssertEqual(approval.eventID, "fixture-event"); XCTAssertEqual(approval.clientID, "fixture-event-client")
        let binding = try XCTUnwrap(approval.extensionBinding)
        XCTAssertEqual(binding.expiresAt - approval.hostTimestamp, 60_000)
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
        let socket = try XCTUnwrap(server.sockets.last)
        // A replacement outside this session still invalidates the old action.
        try socket.frame("$events", ["type": "waterfall", "event": "approval/request", "eventId": approval.eventID, "agentId": "another-session", "request": ["toolName": "changed_action"]])
        await settle { native.approvals.isEmpty }
        await native.decide(approval, allow: true); XCTAssertEqual(server.approvals, 0)
        let request = ["toolName": "read_file", "reason": "Synthetic tool"]
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
