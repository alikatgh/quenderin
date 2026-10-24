import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import QuenderinKit

@MainActor
final class RemoteHarnessBotReadTests: XCTestCase {
    private final class Clock: RemoteHarnessClock {
        var nowEpochMilliseconds: Int64 = 1
        var monotonicMilliseconds: Int64 = 1
    }
    private final class Journal: RemoteHarnessCommandJournal {
        var writes = 0
        var outcomes = 0
        func persistBeforeDispatch(_ command: RemoteHarnessJournalCommand) throws { writes += 1 }
        func recordOutcome(commandID: String, outcome: RemoteHarnessJournalOutcome) throws { outcomes += 1 }
    }
    private final class Port: RemoteHarnessBusinessPort {
        var sent: [Data] = []
        var invalidations = 0
        var onSend: ((Data, RemoteHarnessBinding) throws -> Void)?
        func send(_ data: Data, binding: RemoteHarnessBinding) throws {
            sent.append(data); try onSend?(data, binding)
        }
        func invalidate(binding: RemoteHarnessBinding) { invalidations += 1 }
    }
    private struct Harness {
        let coordinator: RemoteHarnessCoordinator
        let port: Port
        let journal: Journal
        let clock: Clock
        let binding: RemoteHarnessBinding
    }
    private func fixtures() throws -> [String: RemoteHarnessJSON] {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        return try RemoteHarnessJSON(data: Data(contentsOf: root.appendingPathComponent("shared/remote-harness-bot-read-fixtures.json"))).fields()
    }
    private func fixture(_ name: String) throws -> RemoteHarnessJSON {
        try fixtures().required("valid").fields().required(name)
    }
    private func capabilities() throws -> [String] {
        try fixtures().required("capabilities").elements().map { try $0.stringValue() }
    }
    private func response(_ requestID: String, _ result: RemoteHarnessJSON) throws -> Data {
        try RemoteHarnessJSON.object(["v": .integer(1), "id": .string("host-frame"), "type": .string("rpc.response"),
            "timestamp": .integer(2), "payload": .object(["requestId": .string(requestID), "result": result])]).data
    }
    private func event(_ streamID: String, _ value: RemoteHarnessJSON) throws -> Data {
        try RemoteHarnessJSON.object(["v": .integer(1), "id": .string("host-event"), "type": .string("event"), "timestamp": .integer(2),
            "payload": .object(["event": .string("harness.remote.frame"), "data": .object(["streamId": .string(streamID), "hasValue": .boolean(true), "value": value])])]).data
    }
    private func negotiate(_ coordinator: RemoteHarnessCoordinator, binding: RemoteHarnessBinding, capabilities: [String]) throws {
        let rpc = try coordinator.perform(.describe()) { _ in }
        try coordinator.receive(response(rpc, .object(["capabilities": .array(capabilities.map { try .string($0) })])), authenticatedBinding: binding)
    }
    private func harness(workspace: String? = "workspace-a", session: String? = nil, capabilities: [String]? = nil, clientDeviceID: String? = nil) throws -> Harness {
        let port = Port(), journal = Journal(), clock = Clock()
        let binding = try RemoteHarnessBinding(generation: 1, hostID: "host-a", workspaceID: workspace, sessionID: session, clientDeviceID: clientDeviceID)
        let coordinator = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try coordinator.connect(authenticatedBinding: binding)
        try negotiate(coordinator, binding: binding, capabilities: capabilities ?? self.capabilities())
        return Harness(coordinator: coordinator, port: port, journal: journal, clock: clock, binding: binding)
    }
    private func replacing(_ value: RemoteHarnessJSON, _ updates: [String: RemoteHarnessJSON]) throws -> RemoteHarnessJSON {
        var fields = try value.fields()
        fields.merge(updates) { _, new in new }
        return try .object(fields)
    }
    private func roster(_ updates: [String: RemoteHarnessJSON]) throws -> RemoteHarnessJSON {
        let outer = try fixture("response"), json = try outer.fields().required("json")
        let updated = try replacing(json.fields().required("value"), updates)
        return try replacing(outer, ["json": replacing(json, ["value": updated])])
    }
    private func bot(_ updates: [String: RemoteHarnessJSON] = [:]) throws -> RemoteHarnessJSON {
        let first = try fixture("response").fields().required("json").fields().required("value").fields().required("bots").elements()[0]
        return try replacing(first, updates)
    }
    private func parse(_ result: RemoteHarnessJSON, workspace: String = "workspace-a") throws -> RemoteHarnessBotRoster {
        try RemoteHarnessBotRoster(routeResult: result, expectedWorkspaceID: workspace)
    }

    func testSharedValidFixtureUsesRawRouteAndKeepsGatewayIndependent() throws {
        let h = try harness(), raw = try fixture("response")
        let operation = try RemoteHarnessOperation.botRoster(workspaceID: "workspace-a")
        XCTAssertEqual(operation.method.rawValue, "plugin.route.call")
        XCTAssertEqual(operation.workspaceID, "workspace-a")
        XCTAssertNil(operation.sessionID); XCTAssertFalse(operation.isMutation)
        let expected = try JSONSerialization.jsonObject(with: fixture("request").data) as? NSDictionary
        XCTAssertEqual(try JSONSerialization.jsonObject(with: operation.params.data) as? NSDictionary, expected)
        let snapshot = try parse(raw)
        XCTAssertEqual(snapshot.schemaVersion, 1); XCTAssertEqual(snapshot.revision, 7)
        XCTAssertTrue(snapshot.readOnly); XCTAssertEqual(snapshot.bots.count, 2)
        XCTAssertEqual(snapshot.bots[1].name, "Туслагч 助手")
        XCTAssertNil(snapshot.bots[1].model); XCTAssertNil(snapshot.bots[1].permission)
        XCTAssertThrowsError(try RemoteHarnessGatewayResult(raw))
        XCTAssertThrowsError(try parse(fixture("source")))
        var received: RemoteHarnessBotRoster?
        let rpc = try h.coordinator.readBotRoster { if case .success(let value) = $0 { received = value } }
        try h.coordinator.receive(response(rpc, raw), authenticatedBinding: h.binding)
        XCTAssertEqual(received, snapshot)
        XCTAssertEqual(h.journal.writes, 0); XCTAssertEqual(h.journal.outcomes, 0)
        let sessionRPC = try h.coordinator.perform(.sessionList()) { result in
            if case .response(let value?) = result { XCTAssertEqual(try? value.fields().required("items").elements().count, 0) }
            else { XCTFail("Session Gateway result changed") }
        }
        try h.coordinator.receive(response(sessionRPC, .object(["ok": .boolean(true), "value": .object(["items": .array([])])])), authenticatedBinding: h.binding)
        XCTAssertEqual(h.coordinator.stopState, .notRequested)
        XCTAssertEqual(h.coordinator.pendingApprovalRequests.count, 0)
    }

    func testCapturedHostRuntimeResultPassesThroughTypedNativeReadWithoutEffects() throws {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let document = try RemoteHarnessJSON(data: Data(contentsOf: root.appendingPathComponent("shared/remote-harness-bot-runtime-facts.json"))).fields()
        XCTAssertEqual(try document.required("schemaVersion").integerValue(), 1)
        let provenance = try document.required("provenance").fields(), capture = try document.required("capture").fields()
        XCTAssertEqual(try provenance.text("sourceRevision"), "91f3bfa30a2af533c8663fa8e957fafdfac5725e")
        XCTAssertEqual(try provenance.required("workflowRunId").integerValue(), 40_084_776_342)
        XCTAssertEqual(try provenance.required("workflowJobId").integerValue(), 120_845_355_394)
        XCTAssertEqual(try provenance.text("rawResultSHA256"), "3f2dd458164967b5ebd4ca892cedaeb94cf145a290eb5294b4b35137f7161723")
        XCTAssertEqual(try capture.required("schema").integerValue(), 1)
        XCTAssertEqual(try capture.text("harnessRevision"), "1600d8a1e140dcde43a1a0941940a0480712c011")
        XCTAssertEqual(try capture.text("remoteRevision"), "9a60e783ec1ceaff6116b0462a2863f07f602a55")
        XCTAssertEqual(try capture.text("botRevision"), "1bebe826f74e9a72cabafd3b80602b05af867b38")
        let effects = try capture.required("readEffects").fields()
        XCTAssertEqual(Set(effects.keys), Set(["modelCalls", "refreshCalls", "loadCalls", "bootstrapCalls", "secretReads", "agentStarts", "stateWrites", "catalogCalls"]))
        for (name, count) in effects { XCTAssertEqual(try count.integerValue(), 0, name) }
        let workspace = try capture.text("workspaceId"), rawData = Data(try capture.text("rawResult").utf8)
        #if canImport(CryptoKit)
        XCTAssertEqual(SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined(), try provenance.text("rawResultSHA256"))
        #endif
        XCTAssertEqual(try JSONSerialization.jsonObject(with: rawData) as? NSDictionary,
            try JSONSerialization.jsonObject(with: capture.required("result").data) as? NSDictionary)
        let h = try harness(workspace: workspace, session: "fixture-bot-part")
        let approvals = h.coordinator.pendingApprovalRequests
        var received: RemoteHarnessBotRoster?
        let rpc = try h.coordinator.readBotRoster { result in
            switch result {
            case .success(let roster): received = roster
            case .failure(let error): XCTFail("Captured Host read failed: \(error)")
            }
        }
        let request = try RemoteHarnessCodec().decode(XCTUnwrap(h.port.sent.last))
        guard case .request(.pluginRouteCall, let params) = request.body else { return XCTFail("Expected plugin route read") }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: params.data) as? NSDictionary,
            try JSONSerialization.jsonObject(with: capture.required("request").data) as? NSDictionary)
        let wire = try response(rpc, RemoteHarnessJSON(data: rawData))
        guard case .response(_, let raw) = try RemoteHarnessCodec().decode(wire).body else { return XCTFail("Expected captured route response") }
        XCTAssertEqual(raw.data, rawData, "The exact captured result bytes reach the native coordinator")
        try h.coordinator.receive(wire, authenticatedBinding: h.binding)
        let roster = try XCTUnwrap(received), bot = try XCTUnwrap(roster.bots.first)
        XCTAssertEqual(roster.schemaVersion, 1); XCTAssertEqual(roster.workspaceID, workspace); XCTAssertEqual(roster.revision, 8)
        XCTAssertFalse(roster.readOnly); XCTAssertEqual(roster.bots.count, 1)
        XCTAssertEqual(bot.id, "fixture-bot"); XCTAssertEqual(bot.name, "Researcher"); XCTAssertEqual(bot.sessionID, "fixture-bot-part")
        XCTAssertEqual(bot.model, "fixture/scripted"); XCTAssertEqual(bot.permission, "read-only")
        XCTAssertEqual(h.coordinator.pendingApprovalRequests, approvals); XCTAssertEqual(h.coordinator.stopState, .notRequested)
        XCTAssertEqual(h.journal.writes, 0); XCTAssertEqual(h.journal.outcomes, 0)
        XCTAssertEqual(h.coordinator.binding, h.binding); XCTAssertEqual(h.port.invalidations, 0); XCTAssertEqual(h.coordinator.pendingRPCCount, 0)
    }

    func testEverySharedInvalidRequestIsRejectedBeforeDispatch() throws {
        for item in try fixtures().required("invalidRequests").elements() {
            let fields = try item.fields(), id = try fields.text("id"), h = try harness()
            let before = h.port.sent.count
            XCTAssertThrowsError(try h.coordinator.perform(RemoteHarnessOperation(method: .pluginRouteCall, params: fields.required("params"))) { _ in }, id)
            XCTAssertEqual(h.port.sent.count, before, id)
            XCTAssertEqual(h.coordinator.pendingRPCCount, 0, id)
            XCTAssertEqual(h.journal.writes, 0, id)
            print("REMOTE_BOT_READ_REQUEST_PASS " + id)
        }
    }

    func testEverySharedInvalidResponseFailsWithFixedDiagnosticAndNoJournal() throws {
        for item in try fixtures().required("invalidResponses").elements() {
            let fields = try item.fields(), id = try fields.text("id"), raw = try fields.required("result"), h = try harness()
            XCTAssertThrowsError(try parse(raw), id)
            var outcomes: [RemoteHarnessCompletion] = []
            let rpc = try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { outcomes.append($0) }
            XCTAssertNoThrow(try h.coordinator.receive(response(rpc, raw), authenticatedBinding: h.binding), id)
            XCTAssertEqual(outcomes.count, 1, id)
            guard case .failed = outcomes.first else { XCTFail(id); continue }
            XCTAssertFalse(String(describing: outcomes).contains("PRIVATE"), id)
            XCTAssertEqual(h.journal.writes, 0, id); XCTAssertEqual(h.journal.outcomes, 0, id)
            XCTAssertEqual(h.port.sent.count, 2, id)
            XCTAssertEqual(h.coordinator.binding, h.binding, id)
            XCTAssertTrue(h.coordinator.supportsBotRead, id)
            XCTAssertEqual(h.port.invalidations, 0, id)
            print("REMOTE_BOT_READ_RESPONSE_PASS " + id)
        }
    }

    func testBothCapabilitiesRequiredAndDiscoveryScopeCannotRead() throws {
        for caps in [["harness.remote.v3"], ["harness.remote.v3", "plugin.route.v1"], ["harness.remote.v3", "quenderin.bot.read.v1"]] {
            let h = try harness(capabilities: caps)
            XCTAssertFalse(h.coordinator.supportsBotRead)
            XCTAssertThrowsError(try h.coordinator.readBotRoster { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .unsupportedCapability) }
            XCTAssertEqual(h.port.sent.count, 1)
        }
        let h = try harness(workspace: nil)
        XCTAssertFalse(h.coordinator.supportsBotRead)
        XCTAssertThrowsError(try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { _ in })
        XCTAssertThrowsError(try h.coordinator.readBotRoster { _ in })
        XCTAssertEqual(h.journal.writes, 0)
        let port = Port(), journal = Journal(), clock = Clock(), binding = try RemoteHarnessBinding(generation: 1, hostID: "host", workspaceID: "workspace-a")
        let cold = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try cold.connect(authenticatedBinding: binding)
        XCTAssertThrowsError(try cold.readBotRoster { _ in })
        XCTAssertTrue(port.sent.isEmpty)
    }

    func testRenegotiationSuspendsReadsAndOlderDescribeCannotRestoreCapability() throws {
        let h = try harness()
        XCTAssertTrue(h.coordinator.supportsBotRead)
        let old = try h.coordinator.perform(.describe()) { _ in }
        XCTAssertFalse(h.coordinator.supportsBotRead)
        XCTAssertThrowsError(try h.coordinator.readBotRoster { _ in })
        let newest = try h.coordinator.perform(.describe()) { _ in }
        try h.coordinator.receive(response(newest, .object(["capabilities": .array([.string("harness.remote.v3")])])), authenticatedBinding: h.binding)
        try h.coordinator.receive(response(old, .object(["capabilities": .array(capabilities().map { try .string($0) })])), authenticatedBinding: h.binding)
        XCTAssertFalse(h.coordinator.supportsBotRead)
        try negotiate(h.coordinator, binding: h.binding, capabilities: capabilities())
        XCTAssertTrue(h.coordinator.supportsBotRead)
        h.coordinator.disconnect(); XCTAssertFalse(h.coordinator.supportsBotRead)
    }

    func testReconnectAndStaleCallbacksNeverReplayOrCompleteANewRead() throws {
        let h = try harness(), raw = try fixture("response")
        var old: [RemoteHarnessCompletion] = [], current: [RemoteHarnessCompletion] = []
        let oldRPC = try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { old.append($0) }
        h.coordinator.disconnect()
        XCTAssertEqual(old, [.failed(.disconnected)])
        let newer = try RemoteHarnessBinding(generation: 2, hostID: "host-a", workspaceID: "workspace-a")
        try h.coordinator.connect(authenticatedBinding: newer)
        XCTAssertThrowsError(try h.coordinator.readBotRoster { _ in })
        try negotiate(h.coordinator, binding: newer, capabilities: capabilities())
        let rpc = try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { current.append($0) }
        let sent = h.port.sent.count
        try h.coordinator.receive(response(rpc, raw), authenticatedBinding: h.binding)
        try h.coordinator.receive(response(oldRPC, raw), authenticatedBinding: newer)
        XCTAssertTrue(current.isEmpty); XCTAssertEqual(h.coordinator.pendingRPCCount, 1)
        try h.coordinator.receive(response(rpc, raw), authenticatedBinding: newer)
        XCTAssertEqual(current, [.response(raw)])
        try h.coordinator.receive(response(rpc, raw), authenticatedBinding: newer)
        XCTAssertEqual(current.count, 1); XCTAssertEqual(old.count, 1)
        XCTAssertEqual(h.port.sent.count, sent)
        XCTAssertEqual(h.journal.writes, 0); XCTAssertEqual(h.journal.outcomes, 0)
    }

    func testUTF8WorkspaceBindingAndDuplicateIdentitiesDoNotNormalize() throws {
        let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed) // Swift's default equality is intentionally insufficient.
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        let h = try harness(workspace: composed)
        XCTAssertThrowsError(try h.coordinator.perform(.botRoster(workspaceID: decomposed)) { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .bindingMismatch) }
        let raw = try roster(["workspaceId": .string(composed)])
        XCTAssertThrowsError(try parse(raw, workspace: decomposed))
        var completions = 0
        let rpc = try h.coordinator.perform(.botRoster(workspaceID: composed)) { _ in completions += 1 }
        let wrong = try RemoteHarnessBinding(generation: 1, hostID: "host-a", workspaceID: decomposed)
        try h.coordinator.receive(response(rpc, raw), authenticatedBinding: wrong)
        XCTAssertEqual(completions, 0); XCTAssertEqual(h.coordinator.pendingRPCCount, 1)
        try h.coordinator.receive(response(rpc, raw), authenticatedBinding: h.binding)
        XCTAssertEqual(completions, 1)
        let bots = try [bot(["id": .string(composed), "sessionId": .string(composed)]), bot(["id": .string(decomposed), "sessionId": .string(decomposed)])]
        let snapshot = try parse(roster(["bots": .array(bots)]))
        XCTAssertEqual(snapshot.bots.count, 2)
        XCTAssertNotEqual(snapshot.bots[0], snapshot.bots[1])
        XCTAssertThrowsError(try parse(roster(["bots": .array([bots[0], bots[0]])])))
        let describe = try h.coordinator.perform(.describe()) { _ in }
        let caps = try RemoteHarnessJSON.object(["capabilities": .array(capabilities().map { try .string($0) })])
        try h.coordinator.receive(response(describe, caps), authenticatedBinding: wrong)
        XCTAssertFalse(h.coordinator.supportsBotRead)
        try h.coordinator.receive(response(describe, caps), authenticatedBinding: h.binding)
        XCTAssertTrue(h.coordinator.supportsBotRead)
    }

    func testCapacityDeadlinesAndCommandIDRejectionDoNotJournalOrRetry() throws {
        let h = try harness()
        XCTAssertThrowsError(try h.coordinator.perform(.botRoster(workspaceID: "workspace-a"), commandID: "never-journal") { _ in })
        var outcomes: [RemoteHarnessCompletion] = []
        for _ in 0..<RemoteHarnessLimits.pendingRPCs {
            try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { outcomes.append($0) }
        }
        XCTAssertEqual(h.coordinator.pendingRPCCount, 128)
        XCTAssertThrowsError(try h.coordinator.readBotRoster { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .limitExceeded) }
        let sent = h.port.sent.count
        h.clock.nowEpochMilliseconds = 1 // Deadline is independent of wall clock.
        h.clock.monotonicMilliseconds += RemoteHarnessLimits.deadlineMilliseconds
        h.coordinator.expireDeadlines()
        XCTAssertEqual(outcomes, Array(repeating: .failed(.deadlineExceeded), count: 128))
        XCTAssertEqual(h.coordinator.pendingRPCCount, 0); XCTAssertTrue(h.coordinator.supportsBotRead)
        XCTAssertEqual(h.coordinator.binding, h.binding)
        XCTAssertEqual(h.port.sent.count, sent); XCTAssertEqual(h.port.invalidations, 0)
        XCTAssertEqual(h.journal.writes, 0); XCTAssertEqual(h.journal.outcomes, 0)
        var refreshed: RemoteHarnessBotRoster?
        let rpc = try h.coordinator.readBotRoster { if case .success(let roster) = $0 { refreshed = roster } }
        try h.coordinator.receive(response(rpc, fixture("response")), authenticatedBinding: h.binding)
        XCTAssertNotNil(refreshed, "Expired reads release their pending capacity")
    }

    #if canImport(CryptoKit)
    func testRosterDeadlinePreservesLiveStreamsExactApprovalAndNonexpiredStop() throws {
        let h = try harness(session: "session-a", capabilities: capabilities() + ["quenderin.approvals.v1"], clientDeviceID: "client-a")
        let follow = try h.coordinator.nextStreamID(), events = try h.coordinator.nextStreamID()
        var followUpdates: [RemoteHarnessStreamUpdate] = [], eventUpdates: [RemoteHarnessStreamUpdate] = []
        let followRPC = try h.coordinator.perform(.sessionFollow(streamID: follow, sessionID: "session-a"), onStream: { followUpdates.append($0) }) { _ in }
        try h.coordinator.receive(response(followRPC, .object(["streamId": .string(follow), "opened": .boolean(true)])), authenticatedBinding: h.binding)
        let eventsRPC = try h.coordinator.perform(.events(streamID: events), onStream: { eventUpdates.append($0) }) { _ in }
        try h.coordinator.receive(response(eventsRPC, .object(["streamId": .string(events), "opened": .boolean(true)])), authenticatedBinding: h.binding)
        var reads: [RemoteHarnessError] = [], stop: RemoteHarnessCompletion?
        let read = try h.coordinator.readBotRoster { result in
            if case .failure(let error) = result { reads.append(error) } else { XCTFail("Expired read succeeded") }
        }
        let readDeadline = try XCTUnwrap(h.coordinator.nextDeadline)
        h.clock.monotonicMilliseconds = readDeadline - 1
        try h.coordinator.receive(event(follow, .object(["type": .string("event"), "event": .object(["type": .string("turn/start"), "data": .object(["turn": .integer(1)])])])), authenticatedBinding: h.binding)
        try h.coordinator.receive(event(events, .object(["type": .string("ready"), "clientId": .string("event-client")])), authenticatedBinding: h.binding)
        let request = try RemoteHarnessJSON.object(["toolName": .string("read_file"), "callId": .string("call-a")])
        let extended = try RemoteHarnessApprovalBinding(.object(["hostDeviceId": .string("host-a"), "clientDeviceId": .string("client-a"),
            "workspaceId": .string("workspace-a"), "sessionId": .string("session-a"), "runId": .string("turn:1"), "eventId": .string("approval-a"),
            "actionDigest": .string(RemoteHarnessApprovalDigest.digest(request)), "expiresAt": .integer(60_002)]))
        try h.coordinator.receive(event(events, .object(["type": .string("waterfall"), "event": .string("approval/request"), "eventId": .string("approval-a"),
            "agentId": .string("session-a"), "request": request, "quenderinBinding": extended.json()])), authenticatedBinding: h.binding)
        let approval = try XCTUnwrap(h.coordinator.pendingApprovalRequests.first)
        XCTAssertEqual(approval.extensionBinding, extended)
        let cancel = try h.coordinator.perform(.cancel(sessionID: "session-a"), commandID: "stop-a") { stop = $0 }
        let stopDeadline = h.clock.monotonicMilliseconds + RemoteHarnessLimits.deadlineMilliseconds, sent = h.port.sent.count
        h.clock.monotonicMilliseconds = readDeadline
        h.coordinator.expireDeadlines()
        XCTAssertEqual(reads, [.deadlineExceeded]); XCTAssertNil(stop)
        XCTAssertEqual(h.coordinator.binding, h.binding); XCTAssertTrue(h.coordinator.supportsBotRead)
        XCTAssertEqual(h.coordinator.activeStreamCount, 2); XCTAssertEqual(h.coordinator.pendingRPCCount, 1)
        XCTAssertEqual(h.coordinator.nextDeadline, stopDeadline); XCTAssertEqual(h.coordinator.stopState, .requested)
        XCTAssertEqual(h.coordinator.pendingApprovalRequests, [approval])
        XCTAssertEqual(followUpdates.count, 1); XCTAssertEqual(eventUpdates.count, 2)
        XCTAssertEqual(h.port.invalidations, 0); XCTAssertEqual(h.port.sent.count, sent)
        XCTAssertEqual(h.journal.writes, 1); XCTAssertEqual(h.journal.outcomes, 0)
        try h.coordinator.receive(response(read, fixture("response")), authenticatedBinding: h.binding)
        XCTAssertEqual(reads, [.deadlineExceeded]); XCTAssertEqual(h.coordinator.pendingRPCCount, 1)
        XCTAssertEqual(h.coordinator.pendingApprovalRequests, [approval]); XCTAssertEqual(h.port.sent.count, sent)
        try h.coordinator.receive(event(follow, .object(["type": .string("keepalive")])), authenticatedBinding: h.binding)
        XCTAssertEqual(followUpdates.count, 2, "The live follow listener still receives frames")
        let decision = try h.coordinator.perform(.boundApproval(clientID: approval.clientID, binding: extended, allow: true), commandID: "approve-a") { _ in }
        try h.coordinator.receive(response(decision, .object(["ok": .boolean(true), "value": .object(["recorded": .boolean(true)])])), authenticatedBinding: h.binding)
        try h.coordinator.receive(response(cancel, .object(["ok": .boolean(true), "value": .object(["accepted": .boolean(true)])])), authenticatedBinding: h.binding)
        XCTAssertEqual(h.coordinator.stopState, .receiptReceived); XCTAssertNotNil(stop)
        XCTAssertEqual(h.coordinator.pendingRPCCount, 0); XCTAssertEqual(h.coordinator.activeStreamCount, 2)
        XCTAssertEqual(h.journal.writes, 2); XCTAssertEqual(h.journal.outcomes, 2); XCTAssertEqual(h.port.invalidations, 0)
    }
    #endif

    func testOrdinaryRPCDeadlineStillRetiresConnectionAndLeavesSentStopUnknown() throws {
        let h = try harness(session: "session-a")
        var ordinary: RemoteHarnessCompletion?, read: RemoteHarnessCompletion?, stop: RemoteHarnessCompletion?
        try h.coordinator.perform(.modelCatalog()) { ordinary = $0 }
        let deadline = try XCTUnwrap(h.coordinator.nextDeadline)
        h.clock.monotonicMilliseconds += 1
        try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { read = $0 }
        try h.coordinator.perform(.cancel(sessionID: "session-a"), commandID: "stop-a") { stop = $0 }
        let sent = h.port.sent.count
        h.clock.monotonicMilliseconds = deadline
        h.coordinator.expireDeadlines()
        XCTAssertEqual(ordinary, .failed(.deadlineExceeded)); XCTAssertEqual(read, .failed(.deadlineExceeded)); XCTAssertEqual(stop, .outcomeUnknown)
        XCTAssertNil(h.coordinator.binding); XCTAssertFalse(h.coordinator.supportsBotRead); XCTAssertEqual(h.coordinator.stopState, .outcomeUnknown)
        XCTAssertEqual(h.coordinator.pendingRPCCount, 0); XCTAssertEqual(h.port.invalidations, 1); XCTAssertEqual(h.port.sent.count, sent)
        XCTAssertEqual(h.journal.writes, 1); XCTAssertEqual(h.journal.outcomes, 1)
    }

    func testReentrantRosterDeadlineCompletionCannotExpireANewerGeneration() throws {
        let h = try harness(), newer = try RemoteHarnessBinding(generation: 2, hostID: "host-a", workspaceID: "workspace-a")
        var first: RemoteHarnessCompletion?, second: RemoteHarnessCompletion?, ordinary: RemoteHarnessCompletion?, current: RemoteHarnessCompletion?
        var callbackError: Error?, currentRPC: String?
        let raw = try fixture("response")
        try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { completion in
            first = completion
            do {
                try h.coordinator.connect(authenticatedBinding: newer)
                try self.negotiate(h.coordinator, binding: newer, capabilities: self.capabilities())
                currentRPC = try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { current = $0 }
            } catch { callbackError = error }
        }
        try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { second = $0 }
        try h.coordinator.perform(.modelCatalog()) { ordinary = $0 }
        h.clock.monotonicMilliseconds += RemoteHarnessLimits.deadlineMilliseconds
        h.coordinator.expireDeadlines()
        XCTAssertNil(callbackError); XCTAssertEqual(first, .failed(.deadlineExceeded))
        XCTAssertEqual(second, .failed(.disconnected)); XCTAssertEqual(ordinary, .failed(.disconnected))
        XCTAssertEqual(h.coordinator.binding, newer); XCTAssertTrue(h.coordinator.supportsBotRead)
        XCTAssertEqual(h.coordinator.pendingRPCCount, 1); XCTAssertNil(current); XCTAssertEqual(h.port.invalidations, 1)
        try h.coordinator.receive(response(XCTUnwrap(currentRPC), raw), authenticatedBinding: newer)
        XCTAssertEqual(current, .response(raw)); XCTAssertEqual(h.coordinator.pendingRPCCount, 0)
        XCTAssertEqual(h.journal.writes, 0); XCTAssertEqual(h.journal.outcomes, 0)
    }

    func testMalformedCanonicalEquivalentBindingCannotRetireReadOrStop() throws {
        let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
        let h = try harness(workspace: composed, session: "session-a")
        let wrong = try RemoteHarnessBinding(generation: h.binding.generation, hostID: h.binding.hostID,
            workspaceID: decomposed, sessionID: h.binding.sessionID)
        XCTAssertEqual(h.binding, wrong) // The synthesized equality is insufficient at this boundary.
        var read: [RemoteHarnessCompletion] = [], stop: [RemoteHarnessCompletion] = []
        let cancelRPC = try h.coordinator.perform(.cancel(sessionID: "session-a"), commandID: "stop-a") { stop.append($0) }
        let readRPC = try h.coordinator.perform(.botRoster(workspaceID: composed)) { read.append($0) }
        let sent = h.port.sent.count, deadline = h.coordinator.nextDeadline
        for malformed in [Data([0xFF]), Data("{".utf8)] {
            XCTAssertNoThrow(try h.coordinator.receive(malformed, authenticatedBinding: wrong))
            XCTAssertTrue(read.isEmpty); XCTAssertTrue(stop.isEmpty)
            XCTAssertEqual(h.coordinator.pendingRPCCount, 2)
            XCTAssertEqual(h.coordinator.stopState, .requested)
            XCTAssertEqual(h.coordinator.nextDeadline, deadline)
            XCTAssertTrue(h.coordinator.supportsBotRead)
            XCTAssertEqual(h.port.invalidations, 0); XCTAssertEqual(h.port.sent.count, sent)
            XCTAssertEqual(h.journal.writes, 1); XCTAssertEqual(h.journal.outcomes, 0)
            XCTAssertTrue(try XCTUnwrap(h.coordinator.binding?.workspaceID).utf8.elementsEqual(composed.utf8))
        }
        let raw = try roster(["workspaceId": .string(composed)])
        try h.coordinator.receive(response(readRPC, raw), authenticatedBinding: h.binding)
        XCTAssertEqual(read, [.response(raw)]); XCTAssertTrue(stop.isEmpty)
        XCTAssertEqual(h.coordinator.pendingRPCCount, 1); XCTAssertEqual(h.coordinator.stopState, .requested)
        try h.coordinator.receive(response(cancelRPC, .object(["ok": .boolean(true), "value": .object(["accepted": .boolean(true)])])), authenticatedBinding: h.binding)
        XCTAssertEqual(h.coordinator.stopState, .receiptReceived)
        XCTAssertEqual(stop.count, 1); XCTAssertEqual(h.coordinator.pendingRPCCount, 0)
        XCTAssertEqual(h.port.invalidations, 0); XCTAssertEqual(h.port.sent.count, sent)
        XCTAssertEqual(h.journal.writes, 1); XCTAssertEqual(h.journal.outcomes, 1)
    }

    func testRPCErrorPayloadIsNeverExposedAndSynchronousSuccessIsSupported() throws {
        let h = try harness()
        var result: RemoteHarnessCompletion?
        let rpc = try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { result = $0 }
        let error = try RemoteHarnessJSON.object(["v": .integer(1), "id": .string("host-error"), "type": .string("rpc.error"), "timestamp": .integer(2),
            "payload": .object(["requestId": .string(rpc), "code": .string("UNAVAILABLE"), "message": .string("PRIVATE_HOST_ERROR"), "retryable": .boolean(true)])])
        try h.coordinator.receive(error.data, authenticatedBinding: h.binding)
        XCTAssertEqual(result, .failed(.invalidMessage)); XCTAssertEqual(h.coordinator.pendingRPCCount, 0)
        XCTAssertEqual(h.port.sent.count, 2)
        let raw = try fixture("response")
        h.port.onSend = { bytes, binding in
            let id = try RemoteHarnessJSON(data: bytes).fields().text("id")
            try h.coordinator.receive(self.response(id, raw), authenticatedBinding: binding)
        }
        var snapshot: RemoteHarnessBotRoster?
        try h.coordinator.readBotRoster { if case .success(let value) = $0 { snapshot = value } }
        XCTAssertEqual(snapshot, try parse(raw)); XCTAssertEqual(h.coordinator.pendingRPCCount, 0)
        XCTAssertEqual(h.journal.writes, 0); XCTAssertEqual(h.journal.outcomes, 0)
    }

    func testRouteFailurePreservesAnInFlightStopAndItsJournal() throws {
        let h = try harness(session: "session-a")
        var stop: RemoteHarnessCompletion?, read: RemoteHarnessCompletion?
        let cancel = try h.coordinator.perform(.cancel(sessionID: "session-a"), commandID: "stop-a") { stop = $0 }
        let rpc = try h.coordinator.perform(.botRoster(workspaceID: "workspace-a")) { read = $0 }
        let unavailable = try RemoteHarnessJSON.object(["status": .integer(404), "json": .object(["privateError": .string("PRIVATE_HOST_ERROR")])])
        try h.coordinator.receive(response(rpc, unavailable), authenticatedBinding: h.binding)
        XCTAssertEqual(read, .failed(.invalidMessage)); XCTAssertNil(stop)
        XCTAssertEqual(h.coordinator.stopState, .requested)
        XCTAssertEqual(h.coordinator.binding, h.binding)
        XCTAssertEqual(h.journal.writes, 1); XCTAssertEqual(h.journal.outcomes, 0)
        XCTAssertEqual(h.coordinator.pendingRPCCount, 1); XCTAssertEqual(h.port.invalidations, 0)
        try h.coordinator.receive(response(cancel, .object(["ok": .boolean(true), "value": .object(["accepted": .boolean(true)])])), authenticatedBinding: h.binding)
        XCTAssertEqual(h.coordinator.stopState, .receiptReceived)
        XCTAssertEqual(h.journal.writes, 1); XCTAssertEqual(h.journal.outcomes, 1)
        XCTAssertNotNil(stop)
    }

    func testSchemaAndUTF8BoundsIncludingExactWireByteLimits() throws {
        let maximumWorkspace = String(repeating: "w", count: 1_024)
        XCTAssertNoThrow(try RemoteHarnessOperation.botRoster(workspaceID: maximumWorkspace))
        XCTAssertThrowsError(try RemoteHarnessOperation.botRoster(workspaceID: maximumWorkspace + "w"))
        XCTAssertThrowsError(try RemoteHarnessOperation.botRoster(workspaceID: "nul\0workspace"))
        XCTAssertThrowsError(try RemoteHarnessOperation.botRoster(workspaceID: String(repeating: "\u{0001}", count: 1_024)))
        let request = try fixture("request").data
        let exactRequest = request + Data(repeating: 32, count: 4_096 - request.count)
        XCTAssertNoThrow(try RemoteHarnessOperation(method: .pluginRouteCall, params: RemoteHarnessJSON(data: exactRequest)))
        XCTAssertThrowsError(try RemoteHarnessOperation(method: .pluginRouteCall, params: RemoteHarnessJSON(data: exactRequest + Data([32]))))
        let raw = try fixture("response").data
        let exactResult = raw + Data(repeating: 32, count: 262_144 - raw.count)
        XCTAssertNoThrow(try RemoteHarnessBotRoster(data: exactResult, expectedWorkspaceID: "workspace-a"))
        XCTAssertThrowsError(try RemoteHarnessBotRoster(data: exactResult + Data([32]), expectedWorkspaceID: "workspace-a"))
        for (key, count) in [("id", 1_024), ("name", 256), ("sessionId", 1_024), ("model", 256), ("permission", 64)] {
            let maximum = String(repeating: "é", count: count / 2)
            XCTAssertNoThrow(try parse(roster(["bots": .array([bot([key: .string(maximum)])])])), key)
            for bad in [maximum + "x", "", "nul\0text"] {
                XCTAssertThrowsError(try parse(roster(["bots": .array([bot([key: .string(bad)])])])), key)
            }
        }
        var hundred: [RemoteHarnessJSON] = []
        for index in 0..<100 { hundred.append(try bot(["id": .string("bot-\(index)"), "sessionId": .string("session-\(index)")])) }
        XCTAssertEqual(try parse(roster(["bots": .array(hundred)])).bots.count, 100)
        hundred.append(try bot(["id": .string("bot-100"), "sessionId": .string("session-100")]))
        XCTAssertThrowsError(try parse(roster(["bots": .array(hundred)])))
        XCTAssertEqual(try parse(roster(["revision": .integer(9_007_199_254_740_991), "readOnly": .boolean(false)])).revision, 9_007_199_254_740_991)
        XCTAssertFalse(try parse(roster(["readOnly": .boolean(false)])).readOnly)
        for number in ["7.0", "7e0", "-0", "-1", "9007199254740992"] {
            XCTAssertThrowsError(try parse(roster(["revision": RemoteHarnessJSON(data: Data(number.utf8))])))
        }
        for raw in [#"{"status":200,"status":200,"json":{}}"#, #"{"status":200,"json":{"ok":true,"ok":true}}"#, #"{"status":200,"json":"\uD800"}"#] {
            XCTAssertThrowsError(try RemoteHarnessBotRoster(data: Data(raw.utf8), expectedWorkspaceID: "workspace-a"))
        }
        XCTAssertThrowsError(try RemoteHarnessBotRoster(data: Data([0xFF]), expectedWorkspaceID: "workspace-a"))
    }

    func testDTODescriptionsAndReflectionAreRedacted() throws {
        let snapshot = try parse(fixture("response"))
        for value in [snapshot as any CustomStringConvertible, snapshot.bots[0] as any CustomStringConvertible] {
            XCTAssertTrue(value.description.contains("redacted")); XCTAssertFalse(value.description.contains("Researcher"))
        }
        XCTAssertTrue(snapshot.customMirror.children.isEmpty)
        XCTAssertTrue(snapshot.bots[0].customMirror.children.isEmpty)
        XCTAssertFalse(String(reflecting: snapshot).contains("workspace-a"))
        XCTAssertFalse(String(reflecting: snapshot.bots[0]).contains("deepseek-flash"))
    }
}
