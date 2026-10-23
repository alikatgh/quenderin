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
    var now: Int64 = 1_000_000
    var lastPromptTimeZone: String?
    func pair(_ suffix: String = "a") -> [String: Any] { ["accessToken": "synthetic-access-token-" + suffix, "refreshToken": "synthetic-refresh-token-" + suffix, "accessTokenExpiresAt": now + 3_600_000, "refreshTokenExpiresAt": 2_593_000_000] }
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
