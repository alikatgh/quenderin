import Foundation
import XCTest
@testable import QuenderinKit

@MainActor
final class RemoteHarnessCarrierTests: XCTestCase {
    private enum Mismatch: Error { case fixture, storage, delivery }
    private final class Clock: RemoteHarnessClock {
        var nowEpochMilliseconds: Int64 = 1
        var monotonicMilliseconds: Int64 = 1
    }
    private final class Journal: RemoteHarnessCommandJournal {
        var commands: [String: RemoteHarnessJournalCommand] = [:]
        var outcomes: [String: RemoteHarnessJournalOutcome] = [:]
        var failWrites = false
        var onPersist: (() -> Void)?
        func persistBeforeDispatch(_ command: RemoteHarnessJournalCommand) throws {
            if failWrites { throw Mismatch.storage }
            guard commands[command.commandID] == nil else { throw RemoteHarnessError.duplicateCommand }
            commands[command.commandID] = command
            onPersist?()
        }
        func recordOutcome(commandID: String, outcome: RemoteHarnessJournalOutcome) throws {
            if failWrites { throw Mismatch.storage }; outcomes[commandID] = outcome
        }
    }
    private final class Port: RemoteHarnessBusinessPort {
        var sent: [Data] = []
        var invalidations = 0
        var onSend: ((Data, RemoteHarnessBinding) throws -> Void)?
        var onInvalidate: ((RemoteHarnessBinding) -> Void)?
        func send(_ data: Data, binding: RemoteHarnessBinding) throws { sent.append(data); try onSend?(data, binding) }
        func invalidate(binding: RemoteHarnessBinding) { invalidations += 1; onInvalidate?(binding) }
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func value(_ object: Any) throws -> RemoteHarnessJSON { try RemoteHarnessJSON(data: json(object)) }
    private func response(_ rpcID: String, _ result: Any) throws -> Data {
        try json(["v": 1, "id": "host-frame", "type": "rpc.response", "timestamp": 2, "payload": ["requestId": rpcID, "result": result]])
    }
    private func event(_ streamID: String, _ value: Any, sessionID: String? = nil) throws -> Data {
        var payload: [String: Any] = ["event": "harness.remote.frame", "data": ["streamId": streamID, "hasValue": true, "value": value]]
        if let sessionID { payload["sessionId"] = sessionID }
        return try json(["v": 1, "id": "host-event", "type": "event", "timestamp": 2, "payload": payload])
    }
    private func binding(_ generation: UInt64 = 1, host: String = "host") throws -> RemoteHarnessBinding {
        try .init(generation: generation, hostID: host, workspaceID: "workspace", sessionID: "session")
    }
    private func ready(_ carrier: RemoteHarnessCoordinator, _ binding: RemoteHarnessBinding) throws {
        try carrier.connect(authenticatedBinding: binding)
        let rpc = try carrier.perform(.describe()) { _ in }
        try carrier.receive(response(rpc, ["capabilities": ["harness.remote.v3"]]), authenticatedBinding: binding)
    }
    private func fixtures(_ category: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/remote-harness-carrier-fixtures.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(document[category] as? [[String: Any]])
    }
    private func require(_ condition: Bool, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else { XCTFail("Remote Harness fixture mismatch: " + id, file: file, line: line); throw Mismatch.fixture }
    }
    private func builder(_ id: String) throws -> RemoteHarnessOperation? {
        switch id {
        case "describe": return try .describe()
        case "session-list": return try .sessionList()
        case "session-create": return try .sessionCreate(workspaceID: "workspace-fixture")
        case "workspace-follow": return try .workspaceFollow(streamID: "stream-fixture")
        case "session-follow": return try .sessionFollow(streamID: "stream-fixture", sessionID: "session-fixture")
        case "history-page": return try .page(sessionID: "session-fixture", throughSeq: 42, beforeSeq: 21)
        case "prompt": return try .prompt(commandID: "command-fixture", sessionID: "session-fixture", text: "Explain 世界", clientTimeZone: "Asia/Ulaanbaatar")
        case "stop": return try .cancel(sessionID: "session-fixture")
        case "control-follow": return try .control(streamID: "stream-fixture")
        case "approval-events": return try .events(streamID: "stream-fixture")
        case "approval-encoding-only": return try .approvalResult(clientID: "event-client-fixture", eventID: "approval-fixture", allow: true)
        case "model-catalog": return try .modelCatalog()
        case "model-selection": return try .selectModel(sessionID: "session-fixture", provider: "deepseek", model: "deepseek-flash", reasoningEffort: "high")
        case "stream-close": return try .close(streamID: "stream-fixture")
        default: return nil
        }
    }

    func testCanonicalRequests() throws {
        for fixture in try fixtures("requests") {
            let id = try XCTUnwrap(fixture["id"] as? String)
            var rejected = false
            do {
                guard let method = RemoteHarnessMethod(rawValue: try XCTUnwrap(fixture["method"] as? String)) else { throw RemoteHarnessError.endpointNotAllowed }
                let operation = try RemoteHarnessOperation(method: method, params: value(XCTUnwrap(fixture["params"])))
                let encoded = try RemoteHarnessCodec().encodeRequest(id: XCTUnwrap(fixture["frameID"] as? String), timestamp: XCTUnwrap((fixture["timestamp"] as? NSNumber)?.int64Value), operation: operation)
                let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
                if fixture["error"] == nil { try require(actual.isEqual(to: XCTUnwrap(fixture["expectedFrame"] as? [String: Any])), id) }
                if let built = try builder(id) {
                    let params = try XCTUnwrap(JSONSerialization.jsonObject(with: built.params.data) as? NSDictionary)
                    try require(built.method == method && params.isEqual(to: XCTUnwrap(fixture["params"] as? [String: Any])), id)
                }
            } catch is RemoteHarnessError { rejected = true }
            try require(rejected == (fixture["error"] != nil), id)
            emitFixturePass("REMOTE_HARNESS_FIXTURE_PASS " + id)
        }
    }
    func testCanonicalFrames() throws {
        for fixture in try fixtures("frames") {
            let id = try XCTUnwrap(fixture["id"] as? String), raw = Data(try XCTUnwrap(fixture["rawJSON"] as? String).utf8)
            var rejected = false
            do {
                let message = try RemoteHarnessCodec().decode(raw)
                if fixture["error"] == nil {
                    let expected = try XCTUnwrap(fixture["expected"] as? [String: Any])
                    try require(message.type.rawValue == expected["type"] as? String && message.rawJSON.data == raw, id)
                    switch message.body {
                    case .response(let requestID, _), .error(let requestID, _): try require(requestID == expected["requestID"] as? String, id)
                    case .event(let name, let data, _, _):
                        try require(name == expected["eventName"] as? String, id)
                        if let streamID = expected["streamID"] as? String { try require(try data.fields().text("streamId") == streamID, id) }
                    case .request: throw Mismatch.fixture
                    }
                }
            } catch is RemoteHarnessError { rejected = true }
            try require(rejected == (fixture["error"] != nil), id)
            emitFixturePass("REMOTE_HARNESS_FIXTURE_PASS " + id)
        }
    }

    func testEarlyStreamValueArrivesBeforeOpenAcknowledgement() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let stream = try carrier.nextStreamID()
        var order: [String] = [], rawValue: Data?
        XCTAssertEqual(Mirror(reflecting: carrier).children.count, 0)
        port.onSend = { data, binding in
            let message = try RemoteHarnessCodec().decode(data)
            guard case .request(.open, _) = message.body else { throw Mismatch.delivery }
            try carrier.receive(self.event(stream, ["type": "snapshot", "opaque": ["reasoning_content": "preserved", "ratio": 1.25]]), authenticatedBinding: binding)
            try carrier.receive(self.response(message.id, ["opened": true, "streamId": stream]), authenticatedBinding: binding)
        }
        try carrier.perform(.sessionFollow(streamID: stream, sessionID: "session"), onStream: {
            if case .value(let value) = $0 { rawValue = value?.data; order.append("value") }
        }) { _ in order.append("ack") }
        XCTAssertEqual(order, ["value", "ack"])
        XCTAssertTrue(String(decoding: try XCTUnwrap(rawValue), as: UTF8.self).contains("reasoning_content"))
        XCTAssertEqual(carrier.activeStreamCount, 1)
    }

    func testJournalFailureDoesNotDispatchAndPromptIDIsPersistentIdentity() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let prompt = try RemoteHarnessOperation.prompt(commandID: "command", sessionID: "session", text: "hello")
        let before = port.sent.count
        journal.failWrites = true
        XCTAssertThrowsError(try carrier.perform(prompt, commandID: "command") { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .journalUnavailable) }
        XCTAssertEqual(port.sent.count, before)
        journal.failWrites = false
        XCTAssertThrowsError(try carrier.perform(prompt, commandID: "different-command") { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .bindingMismatch) }
        port.onSend = { data, _ in
            XCTAssertNotNil(journal.commands["command"])
            let message = try RemoteHarnessCodec().decode(data)
            XCTAssertNotEqual(message.id, "command")
            guard case .request(_, let params) = message.body else { throw Mismatch.delivery }
            let request = try params.fields().required("payload").fields().required("args").fields().required("request").fields()
            XCTAssertEqual(try request.text("requestId"), "command")
        }
        try carrier.perform(prompt, commandID: "command") { _ in }
    }

    func testReentrantJournalRepliesCannotSettleReservedUnsentRequest() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        var result: RemoteHarnessCompletion?, callbackCount = 0, callbackError: Error?
        let before = port.sent.count
        journal.onPersist = {
            do {
                let reserved = try XCTUnwrap(journal.commands["command"])
                try carrier.receive(self.response(reserved.rpcID, ["ok": true, "value": ["receipt": "premature"]]), authenticatedBinding: identity)
                let error = try self.json(["v": 1, "id": "premature-error", "type": "rpc.error", "timestamp": 2,
                                          "payload": ["requestId": reserved.rpcID, "code": "INTERNAL_ERROR", "message": "private"]])
                try carrier.receive(error, authenticatedBinding: identity)
                XCTAssertEqual(port.sent.count, before)
                XCTAssertNil(result); XCTAssertEqual(callbackCount, 0)
                XCTAssertEqual(carrier.pendingRPCCount, 1); XCTAssertTrue(journal.outcomes.isEmpty)
            } catch { callbackError = error }
        }
        port.onSend = { data, binding in
            XCTAssertNil(result); XCTAssertEqual(callbackCount, 0)
            let message = try RemoteHarnessCodec().decode(data)
            try carrier.receive(self.response(message.id, ["ok": true, "value": ["receipt": "dispatched"]]), authenticatedBinding: binding)
        }
        try carrier.perform(.prompt(commandID: "command", sessionID: "session", text: "hello"), commandID: "command") { result = $0; callbackCount += 1 }
        XCTAssertNil(callbackError); XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(result, .response(try value(["receipt": "dispatched"])))
        XCTAssertEqual(journal.outcomes["command"], .responseReceived)
        XCTAssertEqual(carrier.pendingRPCCount, 0); XCTAssertEqual(port.sent.count, before + 1)
    }

    func testOmittedStreamValueAndExplicitNullRemainDistinct() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let stream = try carrier.nextStreamID()
        var values: [RemoteHarnessJSON?] = []
        let rpc = try carrier.perform(.events(streamID: stream), onStream: {
            if case .value(let value) = $0 { values.append(value) }
        }) { _ in }
        let omitted = try json(["v": 1, "id": "omitted", "type": "event", "timestamp": 2,
                                "payload": ["event": "harness.remote.frame", "data": ["streamId": stream, "hasValue": true]]])
        let explicitNull = try event(stream, NSNull())
        try carrier.receive(omitted, authenticatedBinding: identity)
        try carrier.receive(explicitNull, authenticatedBinding: identity)
        XCTAssertEqual(values.count, 2)
        XCTAssertNil(values[0]); XCTAssertEqual(values[1]?.data, Data("null".utf8))
        XCTAssertEqual(try RemoteHarnessCodec().decode(omitted).rawJSON.data, omitted)
        XCTAssertEqual(try RemoteHarnessCodec().decode(explicitNull).rawJSON.data, explicitNull)
        try carrier.receive(response(rpc, ["opened": true, "streamId": stream]), authenticatedBinding: identity)
        XCTAssertNotNil(carrier.binding); XCTAssertEqual(carrier.activeStreamCount, 1)
    }

    func testDisconnectMakesSentMutationUnknownAndReconnectDoesNotReplay() throws {
        let port = Port(), clock = Clock(), journal = Journal(), old = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, old)
        var mutation: RemoteHarnessCompletion?, read: RemoteHarnessCompletion?
        let prompt = try RemoteHarnessOperation.prompt(commandID: "persisted", sessionID: "session", text: "hello")
        let rpc = try carrier.perform(prompt, commandID: "persisted") { mutation = $0 }
        let readRPC = try carrier.perform(.modelCatalog()) { read = $0 }
        carrier.disconnect()
        XCTAssertEqual(mutation, .outcomeUnknown); XCTAssertEqual(read, .failed(.disconnected))
        XCTAssertEqual(journal.outcomes["persisted"], .outcomeUnknown)
        let new = try binding(2); try ready(carrier, new)
        let count = port.sent.count
        try carrier.receive(response(rpc, ["ok": true]), authenticatedBinding: old)
        try carrier.receive(response(readRPC, ["ok": true, "value": [:]]), authenticatedBinding: new)
        XCTAssertEqual(port.sent.count, count)
        XCTAssertThrowsError(try carrier.perform(prompt, commandID: "persisted") { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .duplicateCommand) }
        let stream = try carrier.nextStreamID()
        XCTAssertThrowsError(try carrier.perform(.sessionFollow(streamID: stream, sessionID: "session"), onStream: { _ in }) { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .recoveryRequired) }
        let snapshot = try carrier.perform(.sessionList()) { _ in }
        try carrier.receive(response(snapshot, ["ok": true, "value": ["items": []]]), authenticatedBinding: new)
        try carrier.perform(.sessionFollow(streamID: stream, sessionID: "session"), onStream: { _ in }) { _ in }
        XCTAssertEqual(carrier.activeStreamCount, 1)
        XCTAssertThrowsError(try carrier.connect(authenticatedBinding: old))
    }

    func testCancelReceiptNeedsNewerAuthoritativeSnapshotForStoppedState() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let oldSnapshot = try carrier.perform(.sessionList()) { _ in }
        let stop = try carrier.perform(.cancel(sessionID: "session"), commandID: "stop-command") { _ in }
        XCTAssertEqual(carrier.stopState, .requested)
        try carrier.receive(response(stop, ["ok": true, "value": ["accepted": true]]), authenticatedBinding: identity)
        XCTAssertEqual(carrier.stopState, .receiptReceived)
        try carrier.receive(response(oldSnapshot, ["ok": true, "value": ["items": [["sessionId": "session", "running": false]]]]), authenticatedBinding: identity)
        XCTAssertEqual(carrier.stopState, .receiptReceived)
        let freshSnapshot = try carrier.perform(.sessionList()) { _ in }
        try carrier.receive(response(freshSnapshot, ["ok": true, "value": ["items": [["sessionId": "session", "running": false]]]]), authenticatedBinding: identity)
        XCTAssertEqual(carrier.stopState, .confirmedStopped)
    }

    func testApprovalPreservesRequestAndBothDecisionsFailClosed() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let stream = try carrier.nextStreamID()
        try carrier.perform(.events(streamID: stream), onStream: { _ in }) { _ in }
        try carrier.receive(event(stream, ["type": "ready", "clientId": "event-client"]), authenticatedBinding: identity)
        try carrier.receive(event(stream, ["type": "waterfall", "event": "approval/request", "eventId": "approval", "agentId": "session", "request": ["toolName": "write", "args": ["unknown": [1, 2]], "reason": "private"]]), authenticatedBinding: identity)
        let pending = try XCTUnwrap(carrier.pendingApprovalRequests.first)
        XCTAssertEqual(try pending.request.fields().required("args").fields().required("unknown").elements().count, 2)
        XCTAssertEqual(Mirror(reflecting: pending).children.count, 0)
        let before = port.sent.count
        XCTAssertThrowsError(try carrier.perform(.approvalResult(clientID: "event-client", eventID: "approval", allow: true), commandID: "approve-command") { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .approvalBindingUnavailable) }
        XCTAssertEqual(port.sent.count, before); XCTAssertNil(journal.commands["approve-command"])
        XCTAssertThrowsError(try carrier.perform(.approvalResult(clientID: "other-client", eventID: "approval", allow: false), commandID: "other-client-deny") { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .approvalBindingUnavailable) }
        XCTAssertThrowsError(try carrier.perform(.approvalResult(clientID: "event-client", eventID: "approval", allow: false), commandID: "deny-command") { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .approvalBindingUnavailable) }
        XCTAssertEqual(port.sent.count, before)
        XCTAssertTrue(journal.commands.isEmpty)
        XCTAssertEqual(carrier.pendingApprovalRequests, [pending])
        try carrier.receive(event(stream, ["type": "cancel", "eventId": "approval"]), authenticatedBinding: identity)
        XCTAssertTrue(carrier.pendingApprovalRequests.isEmpty)
    }

    func testReentrantDisconnectCompletionCannotOverwriteNewerConnection() throws {
        let port = Port(), clock = Clock(), journal = Journal()
        let old = try binding(), superseded = try binding(2), newer = try binding(3)
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, old)
        var callbackCount = 0, callbackError: Error?
        try carrier.perform(.modelCatalog()) { completion in
            callbackCount += 1
            XCTAssertEqual(completion, .failed(.disconnected))
            do { try self.ready(carrier, newer) } catch { callbackError = error }
        }
        // connect(2) retires generation 1. Its completion synchronously installs
        // and negotiates generation 3 before the outer connect resumes.
        XCTAssertThrowsError(try carrier.connect(authenticatedBinding: superseded)) { XCTAssertEqual($0 as? RemoteHarnessError, .bindingMismatch) }
        XCTAssertNil(callbackError); XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(carrier.binding, newer)
        XCTAssertEqual(carrier.pendingRPCCount, 0)
        // A stale generation cannot lower the watermark or reset negotiation.
        XCTAssertThrowsError(try carrier.connect(authenticatedBinding: superseded))
        XCTAssertThrowsError(try carrier.connect(authenticatedBinding: newer))
        let rpc = try carrier.perform(.modelCatalog()) { _ in }
        XCTAssertTrue(rpc.hasPrefix("rpc-3-"))
        try carrier.receive(response(rpc, ["ok": true, "value": [:]]), authenticatedBinding: old)
        XCTAssertEqual(carrier.pendingRPCCount, 1)
        try carrier.receive(response(rpc, ["ok": true, "value": [:]]), authenticatedBinding: newer)
        XCTAssertEqual(carrier.pendingRPCCount, 0)
        XCTAssertEqual(carrier.binding, newer)
    }

    func testJournalConsumingDeadlineNeverDispatchesPreparedMutation() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let before = port.sent.count
        var result: RemoteHarnessCompletion?
        journal.onPersist = { clock.monotonicMilliseconds += RemoteHarnessLimits.deadlineMilliseconds }
        XCTAssertThrowsError(try carrier.perform(.prompt(commandID: "expired-command", sessionID: "session", text: "hello"), commandID: "expired-command") { result = $0 }) { XCTAssertEqual($0 as? RemoteHarnessError, .deadlineExceeded) }
        XCTAssertEqual(port.sent.count, before)
        XCTAssertNotNil(journal.commands["expired-command"])
        XCTAssertEqual(journal.outcomes["expired-command"], .notDispatched)
        XCTAssertEqual(result, .failed(.deadlineExceeded))
        XCTAssertEqual(carrier.pendingRPCCount, 0); XCTAssertNil(carrier.binding)
    }

    func testOldSendThrowCannotInvalidateReentrantlyNegotiatedNewConnection() throws {
        let port = Port(), clock = Clock(), journal = Journal()
        let old = try binding(), newer = try binding(2)
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, old)
        var result: RemoteHarnessCompletion?, completionCount = 0
        port.onSend = { data, suppliedBinding in
            XCTAssertEqual(suppliedBinding, old)
            let message = try RemoteHarnessCodec().decode(data)
            guard case .request(.call, _) = message.body else { throw Mismatch.delivery }
            port.onSend = nil
            // The old bytes were handed off, then its channel was replaced.
            // The old send throws only after generation 2 is fully negotiated.
            try self.ready(carrier, newer)
            throw Mismatch.delivery
        }
        try carrier.perform(.prompt(commandID: "old-command", sessionID: "session", text: "hello"), commandID: "old-command") { result = $0; completionCount += 1 }
        XCTAssertEqual(result, .outcomeUnknown); XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(journal.outcomes["old-command"], .outcomeUnknown)
        XCTAssertEqual(port.invalidations, 1)
        XCTAssertEqual(carrier.binding, newer)
        let rpc = try carrier.perform(.modelCatalog()) { _ in }
        try carrier.receive(response(rpc, ["ok": true, "value": [:]]), authenticatedBinding: newer)
        XCTAssertEqual(carrier.binding, newer); XCTAssertEqual(carrier.pendingRPCCount, 0)
    }

    func testOpenErrorCompletionReconnectCannotRetireNewConnection() throws {
        let port = Port(), clock = Clock(), journal = Journal()
        let old = try binding(), newer = try binding(2)
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, old)
        var callbackError: Error?, completionCount = 0, closedStreamCount = 0
        let stream = try carrier.nextStreamID()
        let openRPC = try carrier.perform(.sessionFollow(streamID: stream, sessionID: "session"), onStream: { update in
            if case .failed(.disconnected) = update { closedStreamCount += 1 }
        }) { completion in
            completionCount += 1
            if case .rejected(let failure) = completion { XCTAssertEqual(failure.code, "SESSION_NOT_READY") }
            else { XCTFail("Expected rejected open") }
            do { try self.ready(carrier, newer) } catch { callbackError = error }
        }
        let failure = try json(["v": 1, "id": "host-error", "type": "rpc.error", "timestamp": 2,
                                "payload": ["requestId": openRPC, "code": "SESSION_NOT_READY", "message": "private"]])
        try carrier.receive(failure, authenticatedBinding: old)
        XCTAssertNil(callbackError); XCTAssertEqual(completionCount, 1); XCTAssertEqual(closedStreamCount, 1)
        XCTAssertEqual(port.invalidations, 1)
        XCTAssertEqual(carrier.binding, newer); XCTAssertEqual(carrier.activeStreamCount, 0)
        let rpc = try carrier.perform(.modelCatalog()) { _ in }
        try carrier.receive(response(rpc, ["ok": true, "value": [:]]), authenticatedBinding: newer)
        XCTAssertEqual(carrier.binding, newer); XCTAssertEqual(carrier.pendingRPCCount, 0)
    }

    func testRejectedCloseRetiresChannelAndReleasesFakeHostSlot() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        var hostSlots = Set<String>(), rejectedWhileHostActive = false
        var localCloseCount = 0, unexpectedUpdates = 0, completion: RemoteHarnessCompletion?
        port.onInvalidate = { _ in hostSlots.removeAll() }
        port.onSend = { data, suppliedBinding in
            let message = try RemoteHarnessCodec().decode(data)
            guard case .request(let method, let params) = message.body else { throw Mismatch.delivery }
            let stream = try params.fields().text("streamId")
            if method == .open {
                hostSlots.insert(stream)
                try carrier.receive(self.response(message.id, ["opened": true, "streamId": stream]), authenticatedBinding: suppliedBinding)
            } else if method == .close {
                rejectedWhileHostActive = hostSlots.contains(stream)
                XCTAssertEqual(carrier.activeStreamCount, 1)
                let error = try self.json(["v": 1, "id": "close-error", "type": "rpc.error", "timestamp": 2,
                                           "payload": ["requestId": message.id, "code": "INTERNAL_ERROR", "message": "private"]])
                try carrier.receive(error, authenticatedBinding: suppliedBinding)
            } else { throw Mismatch.delivery }
        }
        let stream = try carrier.nextStreamID()
        try carrier.perform(.control(streamID: stream), onStream: {
            if case .closed(.cancelled, nil) = $0 { localCloseCount += 1 } else { unexpectedUpdates += 1 }
        }) { _ in }
        XCTAssertEqual(hostSlots.count, 1)
        try carrier.perform(.close(streamID: stream)) { completion = $0 }
        guard let completion, case .rejected(let failure) = completion else { return XCTFail("Expected rejected close") }
        XCTAssertEqual(failure.code, "INTERNAL_ERROR")
        XCTAssertTrue(rejectedWhileHostActive); XCTAssertTrue(hostSlots.isEmpty)
        XCTAssertEqual(localCloseCount, 1); XCTAssertEqual(unexpectedUpdates, 0)
        XCTAssertEqual(port.invalidations, 1); XCTAssertNil(carrier.binding)
        XCTAssertEqual(carrier.activeStreamCount, 0)
    }

    func testPendingClosesRetainHostSlotsUntilAcknowledgementOrClosedEvent() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        var streams: [String] = [], closeRPCs: [String: String] = [:], localCloseCount = 0, valuesAfterClose = 0
        for _ in 0..<RemoteHarnessLimits.streams {
            let stream = try carrier.nextStreamID(); streams.append(stream)
            let rpc = try carrier.perform(.control(streamID: stream), onStream: {
                if case .closed(.cancelled, nil) = $0 { localCloseCount += 1 }
                if case .value = $0 { valuesAfterClose += 1 }
            }) { _ in }
            try carrier.receive(response(rpc, ["opened": true, "streamId": stream]), authenticatedBinding: identity)
        }
        for stream in streams {
            closeRPCs[stream] = try carrier.perform(.close(streamID: stream)) { _ in }
            XCTAssertEqual(carrier.activeStreamCount, 16)
            let before = port.sent.count
            XCTAssertThrowsError(try carrier.perform(.control(streamID: carrier.nextStreamID()), onStream: { _ in }) { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .limitExceeded) }
            XCTAssertEqual(port.sent.count, before)
        }
        XCTAssertEqual(localCloseCount, 16)
        try carrier.receive(event(streams[0], ["private": "late frame"]), authenticatedBinding: identity)
        XCTAssertEqual(valuesAfterClose, 0)
        XCTAssertEqual(carrier.pendingRPCCount, 16)
        XCTAssertThrowsError(try carrier.perform(.close(streamID: streams[0])) { _ in })
        // A contextual close acknowledgement releases exactly one Host slot.
        try carrier.receive(response(XCTUnwrap(closeRPCs[streams[0]]), ["closed": true, "streamId": streams[0]]), authenticatedBinding: identity)
        XCTAssertEqual(carrier.activeStreamCount, 15)
        try carrier.perform(.control(streamID: carrier.nextStreamID()), onStream: { _ in }) { _ in }
        XCTAssertEqual(carrier.activeStreamCount, 16)
        // An authoritative closed event can settle a different closing slot
        // before its RPC acknowledgement, without a second listener callback.
        let closed = try json(["v": 1, "id": "closed-event", "type": "event", "timestamp": 2,
                               "payload": ["event": "harness.remote.stream.closed", "data": ["streamId": streams[1], "reason": "cancelled"]]])
        try carrier.receive(closed, authenticatedBinding: identity)
        XCTAssertEqual(carrier.activeStreamCount, 15); XCTAssertEqual(localCloseCount, 16)
        try carrier.perform(.control(streamID: carrier.nextStreamID()), onStream: { _ in }) { _ in }
        XCTAssertEqual(carrier.activeStreamCount, 16)
    }

    func testMalformedCloseAcknowledgementRetiresReservedHostSlot() throws {
        for invalidKind in ["missing", "nonBoolean", "wrongID"] {
            let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
            let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
            try ready(carrier, identity)
            let stream = try carrier.nextStreamID()
            let open = try carrier.perform(.control(streamID: stream), onStream: { _ in }) { _ in }
            try carrier.receive(response(open, ["opened": true, "streamId": stream]), authenticatedBinding: identity)
            let close = try carrier.perform(.close(streamID: stream)) { _ in }
            XCTAssertEqual(carrier.activeStreamCount, 1)
            var result: [String: Any] = ["streamId": stream]
            if invalidKind == "nonBoolean" { result["closed"] = "true" }
            if invalidKind == "wrongID" { result["closed"] = true; result["streamId"] = "other-stream" }
            XCTAssertThrowsError(try carrier.receive(response(close, result), authenticatedBinding: identity))
            XCTAssertEqual(port.invalidations, 1); XCTAssertNil(carrier.binding)
            XCTAssertEqual(carrier.activeStreamCount, 0)
        }
    }

    func testAlreadyAbsentCloseAcknowledgementPreservesUnrelatedSentMutation() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let stream = try carrier.nextStreamID()
        let open = try carrier.perform(.control(streamID: stream), onStream: { _ in }) { _ in }
        try carrier.receive(response(open, ["opened": true, "streamId": stream]), authenticatedBinding: identity)
        var mutationResult: RemoteHarnessCompletion?, closeResult: RemoteHarnessCompletion?
        let mutation = try carrier.perform(.prompt(commandID: "unrelated-command", sessionID: "session", text: "hello"), commandID: "unrelated-command") { mutationResult = $0 }
        let close = try carrier.perform(.close(streamID: stream)) { closeResult = $0 }
        XCTAssertEqual(carrier.activeStreamCount, 1)
        // Host stream completion raced with close handling: its active entry
        // was already absent, so closed:false authoritatively releases the slot.
        let alreadyAbsent: [String: Any] = ["closed": false, "streamId": stream]
        try carrier.receive(response(close, alreadyAbsent), authenticatedBinding: identity)
        XCTAssertEqual(closeResult, .response(try value(alreadyAbsent)))
        XCTAssertEqual(port.invalidations, 0); XCTAssertEqual(carrier.binding, identity)
        XCTAssertEqual(carrier.activeStreamCount, 0)
        XCTAssertEqual(carrier.pendingRPCCount, 1); XCTAssertNil(mutationResult)
        XCTAssertNil(journal.outcomes["unrelated-command"])
        try carrier.receive(response(mutation, ["ok": true]), authenticatedBinding: identity)
        XCTAssertEqual(mutationResult, .response(nil))
        XCTAssertEqual(journal.outcomes["unrelated-command"], .responseReceived)
        XCTAssertEqual(carrier.pendingRPCCount, 0); XCTAssertEqual(carrier.binding, identity)
    }

    func testDeadlineWrongBindingOversizeAndTooLargeMutationNeverReplay() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        var completion: RemoteHarnessCompletion?
        let rpc = try carrier.perform(.prompt(commandID: "command", sessionID: "session", text: "hello"), commandID: "command") { completion = $0 }
        let oversized = Data(repeating: 32, count: RemoteHarnessLimits.frameBytes + 1)
        try carrier.receive(oversized, authenticatedBinding: binding(host: "other-host"))
        XCTAssertNotNil(carrier.binding); XCTAssertNil(completion)
        let tooLarge = try json(["v": 1, "id": "host", "type": "rpc.error", "timestamp": 2, "payload": ["requestId": rpc, "code": "RESPONSE_TOO_LARGE", "message": "private", "retryable": true]])
        let before = port.sent.count
        try carrier.receive(tooLarge, authenticatedBinding: identity)
        XCTAssertEqual(completion, .outcomeUnknown); XCTAssertEqual(port.sent.count, before)
        var timedOut: RemoteHarnessCompletion?
        try carrier.perform(.modelCatalog()) { timedOut = $0 }
        clock.nowEpochMilliseconds = 1 // Wall-clock changes do not extend the deadline.
        clock.monotonicMilliseconds += RemoteHarnessLimits.deadlineMilliseconds
        carrier.expireDeadlines()
        XCTAssertEqual(timedOut, .failed(.deadlineExceeded)); XCTAssertNil(carrier.binding)
        let new = try binding(2); try ready(carrier, new)
        XCTAssertThrowsError(try carrier.receive(oversized, authenticatedBinding: new))
        XCTAssertNil(carrier.binding)
    }

    func testBoundsConflictingCapabilitiesAndLosslessUnknownNumbers() throws {
        let raw = Data(#"{"large":123456789012345678901234567890,"decimal":1.234567890123456789e-100,"opaque":{"unknown":[true,null]}}"#.utf8)
        let object = try RemoteHarnessJSON(data: raw)
        XCTAssertEqual(String(decoding: try object.fields().required("large").data, as: UTF8.self), "123456789012345678901234567890")
        XCTAssertEqual(String(decoding: try object.fields().required("decimal").data, as: UTF8.self), "1.234567890123456789e-100")
        XCTAssertEqual(Mirror(reflecting: object).children.count, 0)
        XCTAssertThrowsError(try RemoteHarnessJSON(data: Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)))
        XCTAssertThrowsError(try RemoteHarnessJSON(data: Data(("[" + Array(repeating: "0", count: 1_025).joined(separator: ",") + "]").utf8)))
        XCTAssertThrowsError(try RemoteHarnessOperation.prompt(commandID: "c", sessionID: "s", text: String(repeating: "界", count: 21_846)))
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try carrier.connect(authenticatedBinding: identity)
        let rpc = try carrier.perform(.describe()) { _ in }
        XCTAssertThrowsError(try carrier.receive(response(rpc, ["capabilities": ["harness.remote.v1", "harness.remote.v3"]]), authenticatedBinding: identity)) { XCTAssertEqual($0 as? RemoteHarnessError, .conflictingCapabilities) }
        XCTAssertNil(carrier.binding)
    }
    func testProtocolIntegerFieldsRequireUnsignedASCIIDigitTokens() throws {
        let invalidFrames = [
            #"{"v":1.0000000000000001,"id":"f","type":"rpc.response","timestamp":2,"payload":{"requestId":"r","result":{}}}"#,
            #"{"v":1,"id":"f","type":"rpc.response","timestamp":1.0,"payload":{"requestId":"r","result":{}}}"#,
            #"{"v":1,"id":"f","type":"rpc.response","timestamp":1e0,"payload":{"requestId":"r","result":{}}}"#,
            #"{"v":1,"id":"f","type":"event","timestamp":2,"payload":{"event":"harness.remote.frame","seq":1.0000000000000001,"data":{}}}"#
        ]
        for frame in invalidFrames {
            XCTAssertThrowsError(try RemoteHarnessCodec().decode(Data(frame.utf8))) { XCTAssertEqual($0 as? RemoteHarnessError, .invalidMessage) }
        }
        for token in ["-1", "1.0", "1e0", "1.0000000000000001", "9007199254740992", "12345678901234567"] {
            XCTAssertThrowsError(try RemoteHarnessJSON(data: Data(token.utf8)).integerValue()) { XCTAssertEqual($0 as? RemoteHarnessError, .invalidMessage) }
        }
        XCTAssertEqual(try RemoteHarnessJSON(data: Data("0".utf8)).integerValue(), 0)
        XCTAssertEqual(try RemoteHarnessJSON(data: Data("9007199254740991".utf8)).integerValue(), 9_007_199_254_740_991)
        let opaque = #"{"v":1,"id":"f","type":"rpc.response","timestamp":2,"payload":{"requestId":"r","result":{"fraction":1.0000000000000001,"exponent":1e0}}}"#
        let decoded = try RemoteHarnessCodec().decode(Data(opaque.utf8))
        guard case .response(_, let result) = decoded.body else { return XCTFail("Expected opaque response") }
        XCTAssertEqual(String(decoding: try result.fields().required("fraction").data, as: UTF8.self), "1.0000000000000001")
        XCTAssertEqual(String(decoding: try result.fields().required("exponent").data, as: UTF8.self), "1e0")
        XCTAssertEqual(decoded.rawJSON.data, Data(opaque.utf8))
    }
    func testPendingAndStreamCapsAndDuplicateResponses() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        for _ in 0..<RemoteHarnessLimits.streams {
            let stream = try carrier.nextStreamID()
            let rpc = try carrier.perform(.control(streamID: stream), onStream: { _ in }) { _ in }
            try carrier.receive(response(rpc, ["opened": true, "streamId": stream]), authenticatedBinding: identity)
        }
        XCTAssertThrowsError(try carrier.perform(.control(streamID: carrier.nextStreamID()), onStream: { _ in }) { _ in })
        var count = 0
        let rpc = try carrier.perform(.modelCatalog()) { _ in count += 1 }
        try carrier.receive(response(rpc, ["ok": true, "value": [:]]), authenticatedBinding: identity)
        try carrier.receive(response(rpc, ["ok": true, "value": [:]]), authenticatedBinding: identity)
        XCTAssertEqual(count, 1)
        for _ in 0..<RemoteHarnessLimits.pendingRPCs { try carrier.perform(.modelCatalog()) { _ in } }
        XCTAssertThrowsError(try carrier.perform(.modelCatalog()) { _ in })
        XCTAssertEqual(carrier.pendingRPCCount, 128)
    }
    func testInvalidMutationResponseSettlesUnknownRatherThanLosingCallback() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        var result: RemoteHarnessCompletion?
        let rpc = try carrier.perform(.cancel(sessionID: "session"), commandID: "stop") { result = $0 }
        XCTAssertThrowsError(try carrier.receive(response(rpc, ["ok": "true"]), authenticatedBinding: identity))
        XCTAssertEqual(result, .outcomeUnknown); XCTAssertEqual(journal.outcomes["stop"], .outcomeUnknown)
    }
    func testEverySessionAndWorkspaceTargetIsCheckedBeforeJournaling() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        let operations: [RemoteHarnessOperation] = try [
            .prompt(commandID: "prompt", sessionID: "other", text: "hello"), .cancel(sessionID: "other"),
            .selectModel(sessionID: "other", provider: "provider", model: "model"),
            .page(sessionID: "other", throughSeq: 2, beforeSeq: 1), .sessionCreate(workspaceID: "other"),
            .sessionFollow(streamID: carrier.nextStreamID(), sessionID: "other")
        ]
        let before = port.sent.count
        for operation in operations {
            XCTAssertThrowsError(try carrier.perform(operation, commandID: operation.isMutation ? (operation.promptCommandID ?? "mutation") : nil, onStream: { _ in }) { _ in }) { XCTAssertEqual($0 as? RemoteHarnessError, .bindingMismatch) }
        }
        XCTAssertEqual(port.sent.count, before); XCTAssertTrue(journal.commands.isEmpty)
    }
    func testFakeHostJourneyKeepsPromptReceiptDistinctFromCancellation() throws {
        let port = Port(), clock = Clock(), journal = Journal(), identity = try binding()
        let carrier = RemoteHarnessCoordinator(port: port, clock: clock, journal: journal)
        try ready(carrier, identity)
        var endpoints: [String] = [], promptResult: RemoteHarnessCompletion?, follows: [RemoteHarnessJSON] = []
        port.onSend = { data, binding in
            let message = try RemoteHarnessCodec().decode(data)
            guard case .request(let method, let params) = message.body else { throw Mismatch.delivery }
            let operation = try RemoteHarnessOperation(method: method, params: params)
            if let endpoint = operation.endpoint { endpoints.append(endpoint) }
            switch operation.endpoint {
            case "session/list": try carrier.receive(self.response(message.id, ["ok": true, "value": ["items": [["sessionId": "session", "running": false]]]]), authenticatedBinding: binding)
            case "session/create": try carrier.receive(self.response(message.id, ["ok": true, "value": ["sessionId": "created-session"]]), authenticatedBinding: binding)
            case "session/modelCatalog": try carrier.receive(self.response(message.id, ["ok": true, "value": ["default": ["provider": "p", "model": "m"], "groups": []]]), authenticatedBinding: binding)
            case "session/selectModel": try carrier.receive(self.response(message.id, ["ok": true, "value": ["selected": ["provider": "p", "model": "m"]]]), authenticatedBinding: binding)
            case "session/prompt":
                XCTAssertNotNil(journal.commands["prompt-command"])
                try carrier.receive(self.response(message.id, ["ok": true]), authenticatedBinding: binding)
            case "session/cancel": try carrier.receive(self.response(message.id, ["ok": true, "value": ["accepted": true]]), authenticatedBinding: binding)
            case "session/follow", "workspace/follow":
                let stream = try XCTUnwrap(operation.streamID)
                try carrier.receive(self.event(stream, ["type": "snapshot", "records": [], "opaque": ["tool": ["unknown": true]]]), authenticatedBinding: binding)
                try carrier.receive(self.response(message.id, ["opened": true, "streamId": stream]), authenticatedBinding: binding)
            default: throw Mismatch.delivery
            }
        }
        try carrier.perform(.workspaceFollow(streamID: carrier.nextStreamID()), onStream: { if case .value(let value) = $0, let value { follows.append(value) } }) { _ in }
        try carrier.perform(.sessionList()) { _ in }
        try carrier.perform(.sessionCreate(workspaceID: "workspace"), commandID: "create-command") { _ in }
        try carrier.perform(.sessionFollow(streamID: carrier.nextStreamID(), sessionID: "session"), onStream: { if case .value(let value) = $0, let value { follows.append(value) } }) { _ in }
        try carrier.perform(.modelCatalog()) { _ in }
        try carrier.perform(.selectModel(sessionID: "session", provider: "p", model: "m"), commandID: "model-command") { _ in }
        try carrier.perform(.prompt(commandID: "prompt-command", sessionID: "session", text: "hello"), commandID: "prompt-command") { promptResult = $0 }
        XCTAssertEqual(promptResult, .response(nil)); XCTAssertEqual(carrier.stopState, .notRequested)
        try carrier.perform(.cancel(sessionID: "session"), commandID: "stop-command") { _ in }
        XCTAssertEqual(carrier.stopState, .receiptReceived)
        try carrier.perform(.sessionList()) { _ in }
        XCTAssertEqual(carrier.stopState, .confirmedStopped); XCTAssertEqual(follows.count, 2)
        XCTAssertEqual(endpoints, ["workspace/follow", "session/list", "session/create", "session/follow", "session/modelCatalog", "session/selectModel", "session/prompt", "session/cancel", "session/list"])
    }
}
