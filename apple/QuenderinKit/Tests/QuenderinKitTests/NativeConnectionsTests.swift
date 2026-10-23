import Foundation
import XCTest
@testable import QuenderinKit

final class NativeConnectionsTests: XCTestCase {
    private let codec = NativeConversationCodec()
    private enum FixtureFailure: Error { case mismatch }

    private func fixtures(_ category: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/native-connections-fixtures.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root[category] as? [[String: Any]])
    }
    private func fixtureID(_ fixture: [String: Any]) throws -> String { try XCTUnwrap(fixture["id"] as? String) }
    private func input(_ fixture: [String: Any]) throws -> Data {
        if let raw = fixture["rawJSON"] as? String { return Data(raw.utf8) }
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["input"]), options: [.sortedKeys])
    }
    private func require(_ condition: Bool, id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            XCTFail("Canonical native connection fixture mismatch: \(id)", file: file, line: line)
            throw FixtureFailure.mismatch
        }
    }
    private func pass(_ id: String) { print("NATIVE_CONNECTION_FIXTURE_PASS \(id)") }
    private func object(_ data: Data) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary) }

    func testCanonicalValidProfiles() throws {
        for fixture in try fixtures("profilesValid") {
            let id = try fixtureID(fixture)
            let profile = try codec.decodeProfile(input(fixture))
            let encoded = try codec.encodeProfile(profile)
            try require(try codec.decodeProfile(encoded) == profile, id: id)
            var expected = try XCTUnwrap(fixture["input"] as? [String: Any])
            if let origin = expected["endpoint"] as? String { expected["endpoint"] = try NativeConnectionOrigin.canonical(origin) }
            try require(try object(encoded).isEqual(to: expected), id: id)
            pass(id)
        }
    }
    func testCanonicalInvalidProfiles() throws {
        for fixture in try fixtures("profilesInvalid") {
            let id = try fixtureID(fixture)
            var rejected = false
            do { _ = try codec.decodeProfile(input(fixture)) }
            catch is NativeConnectionError { rejected = true }
            try require(rejected, id: id)
            pass(id)
        }
    }
    func testCanonicalValidEnvelopes() throws {
        for fixture in try fixtures("envelopesValid") {
            let id = try fixtureID(fixture)
            let envelope = try codec.decodeEnvelope(input(fixture))
            let encoded = try codec.encodeEnvelope(envelope)
            try require(try codec.decodeEnvelope(encoded) == envelope, id: id)
            let expected = try XCTUnwrap(fixture["input"] as? [String: Any])
            try require(try object(encoded).isEqual(to: expected), id: id)
            pass(id)
        }
    }
    func testCanonicalInvalidEnvelopes() throws {
        for fixture in try fixtures("envelopesInvalid") {
            let id = try fixtureID(fixture)
            var rejected = false
            do { _ = try codec.decodeEnvelope(input(fixture)) }
            catch is NativeConnectionError { rejected = true }
            try require(rejected, id: id)
            pass(id)
        }
    }
    func testCanonicalLegacyMigrationUsesExistingDecoderAndPreservesSource() throws {
        for fixture in try fixtures("legacy") {
            let id = try fixtureID(fixture)
            let original = Data(try XCTUnwrap(fixture["swiftSource"] as? String).utf8)
            let retained = original
            let conversationID = try XCTUnwrap(fixture["conversationID"] as? String)
            let envelope = try codec.decodeOrMigrate(original, conversationID: conversationID)
            try require(original == retained, id: id)
            try require(envelope.conversationID == conversationID && envelope.binding.profileID == "local-default"
                        && envelope.binding.kind == .local && envelope.selection == nil && envelope.remoteSession == nil, id: id)
            let actualMessages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope.messages)) as? NSArray
            let expected = try XCTUnwrap(fixture["expectedMessages"] as? [Any])
            try require(actualMessages?.isEqual(to: expected) == true, id: id)
            let legacy = try ConversationStore().decode(original)
            try require(legacy.map(\.text) == envelope.messages.map(\.content), id: id)
            pass(id)
        }
    }

    private func localProfile(id: String = "local-default") throws -> NativeConnectionProfile {
        try NativeConnectionProfile(id: id, kind: .local, displayName: "On this device")
    }
    private func remoteProfile(hostID: String = "host-a", workspaceID: String = "workspace-a",
                               fingerprint: String = String(repeating: "a", count: 64),
                               origin: String = "https://relay.example") throws -> NativeConnectionProfile {
        try NativeConnectionProfile(id: "computer", kind: .remoteHarness, displayName: "Computer", endpoint: origin,
                                    hostID: hostID, hostFingerprint: fingerprint, workspaceID: workspaceID)
    }
    private func approval(expiry: Int64 = 2_000, digest: String = String(repeating: "b", count: 64)) throws -> RemoteApproval {
        try RemoteApproval(approvalID: "approval-a", requestID: "request-original", hostID: "host-a", deviceID: "device-a",
                           workspaceID: "workspace-a", sessionID: "session-a", runID: "run-a", actionDigest: digest, expiresAtEpochMs: expiry)
    }
    private func session(approvals: [RemoteApproval] = [], commands: [PendingRemoteCommand] = []) throws -> RemoteSessionState {
        try RemoteSessionState(hostID: "host-a", deviceID: "device-a", workspaceID: "workspace-a", sessionID: "session-a", runID: "run-a",
                               status: approvals.isEmpty ? .ready : .awaitingApproval, pendingCommands: commands, pendingApprovals: approvals)
    }

    func testDispatchIsPinnedToEveryDestinationField() throws {
        let profile = try remoteProfile()
        let envelope = try NativeConversationEnvelope(conversationID: "conversation", binding: profile.binding, messages: [])
        XCTAssertNoThrow(try envelope.requireDispatch(to: profile))
        for changed in [try remoteProfile(hostID: "host-b"), try remoteProfile(workspaceID: "workspace-b"),
                        try remoteProfile(fingerprint: String(repeating: "c", count: 64)),
                        try remoteProfile(origin: "https://other.example"), try localProfile()] {
            XCTAssertThrowsError(try envelope.requireDispatch(to: changed)) { XCTAssertEqual($0 as? NativeConnectionError, .dispatchMismatch) }
        }
        let local = try NativeConversationEnvelope(conversationID: "local", binding: localProfile().binding, messages: [])
        XCTAssertThrowsError(try local.requireDispatch(to: localProfile(id: "other-local")))
        let renamed = try NativeConnectionProfile(id: "computer", kind: .remoteHarness, displayName: "Renamed",
            endpoint: "HTTPS://RELAY.EXAMPLE:443/", credentialReference: "qcred:rotated", hostID: "host-a",
            hostFingerprint: String(repeating: "a", count: 64), workspaceID: "workspace-a")
        XCTAssertNoThrow(try envelope.requireDispatch(to: renamed))
    }

    func testCompleteProviderRequestKeepsReasoningToolsAndDocumentBytes() throws {
        let reasoning = "Think\n\t e\u{301} 雪 🚀\\"
        let arguments = "  { incomplete provider arguments\n"
        let call = try ProviderToolCall(id: "call-a", name: "read_document", argumentsJSON: arguments)
        let messages = [
            try ProviderMessage(id: "u", role: .user, content: "Read", documents: [ProviderDocument(name: "café.txt", text: "e\u{301}\n")]),
            try ProviderMessage(id: "a", role: .assistant, content: "", reasoningContent: reasoning, toolCalls: [call]),
            try ProviderMessage(id: "t", role: .tool, content: "result", toolCallID: "call-a")
        ]
        let profile = try NativeConnectionProfile(id: "deepseek", kind: .deepseek, displayName: "DeepSeek", endpoint: "https://api.deepseek.com")
        let selected = try ProviderSelection(providerID: "deepseek", modelID: "deepseek-flash", reasoningEffort: .high)
        let envelope = try NativeConversationEnvelope(conversationID: "conversation", binding: profile.binding, selection: selected, messages: messages)
        let restored = try codec.decodeEnvelope(codec.encodeEnvelope(envelope))
        let request = try ProviderRequest(requestID: "request", profile: profile, envelope: restored,
            capabilities: ProviderCapabilities(reasoning: true, toolCalls: true, documents: true, cancellation: true, usage: true), tools: [],
            limits: ProviderRequestLimits(maxOutputTokens: 512, maxToolCalls: 2, deadlineEpochMs: 2_000), nowEpochMs: 1_000)
        XCTAssertEqual(request.messages.count, 3)
        XCTAssertEqual(Data(try XCTUnwrap(request.messages[1].reasoningContent).utf8), Data(reasoning.utf8))
        XCTAssertEqual(Data(request.messages[1].toolCalls[0].argumentsJSON.utf8), Data(arguments.utf8))
        XCTAssertEqual(request.messages[0].documents, messages[0].documents)
        XCTAssertEqual(request.messages[2].toolCallID, "call-a")
        XCTAssertEqual(request.selection, selected)
        XCTAssertEqual(request.requestID, "request")
        XCTAssertThrowsError(try ProviderRequest(requestID: "request", profile: localProfile(), envelope: restored,
            capabilities: request.capabilities, tools: [], limits: request.limits, nowEpochMs: 1_000))
        XCTAssertThrowsError(try ProviderRequest(requestID: "request", profile: profile, envelope: restored,
            capabilities: request.capabilities, tools: [], limits: request.limits, nowEpochMs: 2_000))
    }

    private func providerRequest(messages: [ProviderMessage] = [], effort: ProviderReasoningEffort = .off,
                                 persistSelection: Bool = true, capabilities: ProviderCapabilities,
                                 tools: [ProviderToolDefinition] = []) throws -> ProviderRequest {
        let profile = try localProfile()
        let selection = try ProviderSelection(providerID: "local", modelID: "model", reasoningEffort: effort)
        let envelope = try NativeConversationEnvelope(conversationID: "conversation", binding: profile.binding,
                                                      selection: persistSelection ? selection : nil, messages: messages)
        return try ProviderRequest(requestID: "request", profile: profile, envelope: envelope, capabilities: capabilities,
                                   tools: tools, limits: ProviderRequestLimits(maxOutputTokens: 512, maxToolCalls: 4, deadlineEpochMs: 2_000),
                                   nowEpochMs: 1_000)
    }

    func testProviderCapabilitiesCoverCompleteHistoryAndRequirePersistedSelection() throws {
        let none = ProviderCapabilities(reasoning: false, toolCalls: false, documents: false, cancellation: false, usage: false)
        XCTAssertNoThrow(try providerRequest(capabilities: none))
        XCTAssertThrowsError(try providerRequest(persistSelection: false, capabilities: none))
        XCTAssertThrowsError(try providerRequest(effort: .high, capabilities: none))
        let reasoning = try ProviderMessage(id: "reasoning", role: .assistant, content: "", reasoningContent: "")
        XCTAssertThrowsError(try providerRequest(messages: [reasoning], capabilities: none))
        let call = try ProviderToolCall(id: "call", name: "read", argumentsJSON: "unfinished arguments")
        let assistant = try ProviderMessage(id: "assistant", role: .assistant, content: "", toolCalls: [call])
        XCTAssertThrowsError(try providerRequest(messages: [assistant], capabilities: none))
        let result = try ProviderMessage(id: "result", role: .tool, content: "", toolCallID: "call")
        XCTAssertThrowsError(try providerRequest(messages: [result], capabilities: none))
        let document = try ProviderMessage(id: "doc", role: .user, content: "", documents: [ProviderDocument(name: "notes", text: "")])
        XCTAssertThrowsError(try providerRequest(messages: [document], capabilities: none))
        let definition = try ProviderToolDefinition(name: "read", description: "Read selected notes", parametersJSON: "{}")
        XCTAssertThrowsError(try providerRequest(capabilities: none, tools: [definition]))
        let all = ProviderCapabilities(reasoning: true, toolCalls: true, documents: true, cancellation: true, usage: true)
        XCTAssertNoThrow(try providerRequest(messages: [reasoning, assistant, result, document], effort: .max, capabilities: all, tools: [definition]))
    }

    func testProviderRequestPreflightsAggregateToolPayloads() throws {
        let large = String(repeating: "x", count: 1_048_576)
        let tools = try (0..<9).map { try ProviderToolDefinition(name: "tool-\($0)", description: large, parametersJSON: "{}") }
        let capabilities = ProviderCapabilities(reasoning: false, toolCalls: true, documents: false, cancellation: false, usage: false)
        XCTAssertThrowsError(try providerRequest(capabilities: capabilities, tools: tools)) {
            XCTAssertEqual($0 as? NativeConnectionError, .limitExceeded)
        }
    }

    func testStreamingEventsValidatePayloadsAndKeepOutcomesDistinct() throws {
        let text = ProviderEvent.text(try ProviderTextDelta(messageID: "message", delta: "line\n雪"))
        let reasoning = ProviderEvent.reasoning(try ProviderTextDelta(messageID: "message", delta: "line\n雪"))
        XCTAssertNotEqual(text, reasoning)
        let fragment = ProviderEvent.toolCallFragment(try ProviderToolCallFragment(messageID: "message", index: 127, argumentsDelta: "partial{"))
        if case .toolCallFragment(let value) = fragment {
            XCTAssertNil(value.callID); XCTAssertNil(value.name); XCTAssertEqual(value.argumentsDelta, "partial{")
        } else { XCTFail("Wrong streaming event kind") }
        XCTAssertNoThrow(try ProviderUsage(inputTokens: 0, outputTokens: 9_007_199_254_740_991))
        XCTAssertThrowsError(try ProviderUsage(inputTokens: -1, outputTokens: 0))
        XCTAssertThrowsError(try ProviderUsage(inputTokens: 0, outputTokens: 9_007_199_254_740_992))
        XCTAssertThrowsError(try ProviderTextDelta(messageID: "", delta: ""))
        XCTAssertThrowsError(try ProviderTextDelta(messageID: "message", delta: String(repeating: "x", count: 1_048_577)))
        XCTAssertThrowsError(try ProviderToolCallFragment(messageID: "message", index: -1, argumentsDelta: ""))
        XCTAssertThrowsError(try ProviderToolCallFragment(messageID: "message", index: 128, argumentsDelta: ""))
        XCTAssertThrowsError(try ProviderToolCallFragment(messageID: "message", callID: "", index: 0, argumentsDelta: ""))
        XCTAssertThrowsError(try ProviderToolCallFragment(messageID: "message", name: "../bad", index: 0, argumentsDelta: ""))
        XCTAssertNotEqual(ProviderEvent.completion(.end), .completion(.toolCalls))
        XCTAssertNotEqual(ProviderEvent.completion(.outputLimit), .cancellation)
        XCTAssertNotEqual(ProviderEvent.cancellation, .failure(.outcomeUnknown))
        XCTAssertEqual(ProviderFailureCode.limitExceeded.rawValue, "limitExceeded")
    }

    func testPayloadDiagnosticsAndReflectedDumpsAreRedacted() throws {
        let sentinel = "private-sentinel-for-diagnostic-fixture"
        let message = try ProviderMessage(id: "message", role: .assistant, content: sentinel, reasoningContent: sentinel)
        let tool = try ProviderToolDefinition(name: "tool", description: sentinel, parametersJSON: "{\"description\":\"\(sentinel)\"}")
        let all = ProviderCapabilities(reasoning: true, toolCalls: true, documents: true, cancellation: true, usage: true)
        let request = try providerRequest(messages: [message], capabilities: all, tools: [tool])
        let delta = try ProviderTextDelta(messageID: "message", delta: sentinel)
        let fragment = try ProviderToolCallFragment(messageID: "message", index: 0, argumentsDelta: sentinel)
        let values: [Any] = [message, tool, request, delta, fragment, ProviderEvent.text(delta), ProviderEvent.reasoning(delta), ProviderEvent.toolCallFragment(fragment)]
        for value in values {
            XCTAssertFalse(String(describing: value).contains(sentinel), "Description exposed private fixture data")
            XCTAssertFalse(String(reflecting: value).contains(sentinel), "Debug description exposed private fixture data")
            var output = ""
            dump(value, to: &output)
            XCTAssertFalse(output.contains(sentinel), "Reflected dump exposed private fixture data")
            XCTAssertTrue(Mirror(reflecting: value).children.isEmpty, "Private value exposed reflected fields")
        }
    }

    func testApprovalExpiryMatchingAndOneTimeConsumption() throws {
        let shown = try approval()
        var state = try session(approvals: [shown])
        let unchanged = state
        XCTAssertThrowsError(try state.consumeApproval(shown, decision: .approve, decisionRequestID: "decision-a", nowEpochMs: 2_000)) {
            XCTAssertEqual($0 as? NativeConnectionError, .approvalExpired)
        }
        XCTAssertEqual(state, unchanged)
        let tampered = try approval(digest: String(repeating: "c", count: 64))
        XCTAssertThrowsError(try state.consumeApproval(tampered, decision: .approve, decisionRequestID: "decision-a", nowEpochMs: 1_999))
        XCTAssertEqual(state, unchanged)
        try state.consumeApproval(shown, decision: .approve, decisionRequestID: "decision-a", nowEpochMs: 1_999)
        XCTAssertTrue(state.pendingApprovals.isEmpty)
        XCTAssertEqual(state.pendingCommands.map(\.kind), [.approve])
        XCTAssertEqual(state.pendingCommands.map(\.state), [.prepared])
        XCTAssertThrowsError(try state.consumeApproval(shown, decision: .deny, decisionRequestID: "decision-b", nowEpochMs: 1_999)) {
            XCTAssertEqual($0 as? NativeConnectionError, .approvalUnavailable)
        }
        let envelope = try NativeConversationEnvelope(conversationID: "remote", binding: remoteProfile().binding, messages: [], remoteSession: state)
        var restored = try XCTUnwrap(codec.decodeEnvelope(codec.encodeEnvelope(envelope)).remoteSession)
        XCTAssertThrowsError(try restored.consumeApproval(shown, decision: .approve, decisionRequestID: "decision-c", nowEpochMs: 1_999))
        var denied = try session(approvals: [shown])
        try denied.consumeApproval(shown, decision: .deny, decisionRequestID: "decision-deny", nowEpochMs: 1_999)
        XCTAssertEqual(denied.pendingCommands.first?.kind, .deny)
    }

    func testApprovalPreparationFailureDoesNotConsumePrompt() throws {
        let shown = try approval()
        var state = try session(approvals: [shown], commands: [PendingRemoteCommand(requestID: "duplicate", kind: .send)])
        XCTAssertThrowsError(try state.consumeApproval(shown, decision: .approve, decisionRequestID: "duplicate", nowEpochMs: 1_000))
        XCTAssertEqual(state.pendingApprovals, [shown])
        XCTAssertEqual(state.pendingCommands.count, 1)
        XCTAssertThrowsError(try state.prepareCommand(requestID: "bypass", kind: .approve))
    }

    func testDisconnectDistinguishesUnsentAndUnknownAndNeverReplays() throws {
        var state = try session()
        try state.prepareCommand(requestID: "sent", kind: .send)
        try state.prepareCommand(requestID: "unsent", kind: .send)
        try state.markSent(requestID: "sent")
        state.connectionLost()
        XCTAssertEqual(state.status, .outcomeUnknown)
        XCTAssertEqual(state.pendingCommands.map(\.state), [.outcomeUnknown, .prepared])
        XCTAssertThrowsError(try state.markSent(requestID: "sent"))
        XCTAssertThrowsError(try state.prepareCommand(requestID: "sent", kind: .send))
        let envelope = try NativeConversationEnvelope(conversationID: "remote", binding: remoteProfile().binding, messages: [], remoteSession: state)
        let restored = try XCTUnwrap(codec.decodeEnvelope(codec.encodeEnvelope(envelope)).remoteSession)
        XCTAssertEqual(restored.pendingCommands.map(\.state), [.outcomeUnknown, .prepared])
        XCTAssertEqual(restored.status, .outcomeUnknown)
    }

    func testStopNeedsExactAcknowledgementAfterConnectionLoss() throws {
        var state = try session()
        try state.prepareCommand(requestID: "stop-a", kind: .stop)
        try state.markSent(requestID: "stop-a")
        XCTAssertEqual(state.status, .stopRequested)
        let wrongRun = try RemoteEventIdentity(hostID: "host-a", deviceID: "device-a", workspaceID: "workspace-a", sessionID: "session-a", runID: "run-b")
        let wrongDevice = try RemoteEventIdentity(hostID: "host-a", deviceID: "device-b", workspaceID: "workspace-a", sessionID: "session-a", runID: "run-a")
        for wrong in [wrongRun, wrongDevice] {
            XCTAssertThrowsError(try state.acknowledge(requestID: "stop-a", identity: wrong, eventID: "wrong-event"))
        }
        XCTAssertThrowsError(try state.acknowledge(requestID: "other-request", identity: state.identity))
        XCTAssertEqual(state.status, .stopRequested)
        XCTAssertNil(state.lastConfirmedEventID)
        state.connectionLost()
        XCTAssertEqual(state.status, .outcomeUnknown)
        XCTAssertEqual(state.pendingCommands.first?.state, .outcomeUnknown)
        try state.acknowledge(requestID: "stop-a", identity: state.identity, eventID: "opaque:event/42")
        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.pendingCommands.first?.state, .acknowledged)
        XCTAssertEqual(state.lastConfirmedEventID, "opaque:event/42")
        XCTAssertThrowsError(try state.acknowledge(requestID: "stop-a", identity: state.identity))
    }

    func testStopRequestBlocksEarlierUnsentWork() throws {
        var state = try session()
        try state.prepareCommand(requestID: "unsent", kind: .send)
        try state.prepareCommand(requestID: "stop", kind: .stop)
        let unchanged = state
        XCTAssertThrowsError(try state.markSent(requestID: "unsent"))
        XCTAssertEqual(state, unchanged)
        try state.markSent(requestID: "stop")
        try state.acknowledge(requestID: "stop", identity: state.identity)
        XCTAssertEqual(state.status, .stopped)
        XCTAssertThrowsError(try state.markSent(requestID: "unsent"))
    }

    func testDisconnectedAndUnknownSessionsCannotCreateOrSendMutations() throws {
        let shown = try approval()
        var state = try session(approvals: [shown])
        try state.prepareCommand(requestID: "prepared", kind: .send)
        state.connectionLost()
        XCTAssertEqual(state.status, .outcomeUnknown)
        let retained = state
        XCTAssertThrowsError(try state.prepareCommand(requestID: "new-send", kind: .send))
        XCTAssertThrowsError(try state.prepareCommand(requestID: "new-stop", kind: .stop))
        XCTAssertThrowsError(try state.markSent(requestID: "prepared"))
        XCTAssertThrowsError(try state.consumeApproval(shown, decision: .approve, decisionRequestID: "decision", nowEpochMs: 1_000))
        XCTAssertEqual(state, retained)
        var disconnected = try session()
        disconnected.connectionLost()
        XCTAssertEqual(disconnected.status, .disconnected)
        XCTAssertThrowsError(try disconnected.prepareCommand(requestID: "send", kind: .send))
        var stopped = try session()
        try stopped.prepareCommand(requestID: "stop", kind: .stop)
        try stopped.markSent(requestID: "stop")
        try stopped.acknowledge(requestID: "stop", identity: stopped.identity)
        stopped.connectionLost()
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertThrowsError(try stopped.prepareCommand(requestID: "send", kind: .send))
    }

    func testSendingKeepsOutstandingApprovalVisible() throws {
        let shown = try approval()
        var state = try session(approvals: [shown])
        try state.prepareCommand(requestID: "send", kind: .send)
        try state.markSent(requestID: "send")
        XCTAssertEqual(state.status, .awaitingApproval)
        try state.consumeApproval(shown, decision: .deny, decisionRequestID: "denial", nowEpochMs: 1_000)
        try state.markSent(requestID: "denial")
        XCTAssertEqual(state.status, .running)
    }

    func testUnknownVersionNeverFallsBackToLegacyAndOldAPIsStayUsable() throws {
        let future = Data("{\"schemaVersion\":999,\"messages\":[]}".utf8)
        XCTAssertThrowsError(try codec.decodeOrMigrate(future, conversationID: "legacy"))
        let legacy = [ChatMessage(role: .user, text: "saved", documents: [AttachedDocument(name: "name", text: "source")])]
        let original = try ConversationStore().encode(legacy)
        let migrated = try codec.decodeOrMigrate(original, conversationID: "migrated")
        XCTAssertEqual(try ConversationStore().decode(original).map(\.text), ["saved"])
        XCTAssertEqual(migrated.messages.first?.documents.first?.text, "source")
        XCTAssertEqual(try codec.decodeOrMigrate(Data(), conversationID: "empty").messages, [])
    }

    func testUnsupportedLegacyAssistantAttachmentsFailWithoutDroppingOriginal() throws {
        let original = Data(#"[{"role":"assistant","text":"answer","documents":[{"name":"notes","text":"preserved"}]}]"#.utf8)
        let retained = original
        XCTAssertEqual(try ConversationStore().decode(original).first?.documents.first?.text, "preserved")
        XCTAssertThrowsError(try codec.decodeOrMigrate(original, conversationID: "legacy"))
        XCTAssertEqual(original, retained)
        XCTAssertEqual(try ConversationStore().decode(original).first?.text, "answer")
    }

    func testPublicCodableValuesValidateAndDoNotLeakDecoderPayloads() throws {
        let sensitive = "private-content-marker"
        let invalid = Data("{\"id\":\"m\",\"role\":\"\(sensitive)\",\"content\":\"\(sensitive)\"}".utf8)
        do {
            _ = try JSONDecoder().decode(ProviderMessage.self, from: invalid)
            XCTFail("Invalid public Codable value was accepted")
        } catch {
            XCTAssertTrue(error is NativeConnectionError)
            XCTAssertFalse(String(describing: error).contains(sensitive))
            XCTAssertFalse(error.localizedDescription.contains(sensitive))
        }
        let invalidProfile = Data("{\"id\":\"local\",\"kind\":\"local\",\"displayName\":\"Local\",\"endpoint\":\"https://relay.example\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeConnectionProfile.self, from: invalidProfile))
        let invalidNull = Data("{\"id\":\"m\",\"role\":\"assistant\",\"content\":\"\",\"toolCalls\":null}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderMessage.self, from: invalidNull))
    }

    func testRawJSONBoundsUnicodeAndDuplicateEscapedKeys() throws {
        let duplicate = Data(#"{"id":"local","\u0069d":"other","kind":"local","displayName":"Local"}"#.utf8)
        XCTAssertThrowsError(try codec.decodeProfile(duplicate))
        XCTAssertThrowsError(try codec.decodeProfile(Data([0x7B, 0x22, 0xFF, 0x22, 0x7D])))
        let tooDeep = Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)
        XCTAssertThrowsError(try codec.decodeEnvelope(tooDeep))
        XCTAssertThrowsError(try codec.decodeEnvelope(Data(repeating: 32, count: 8_388_609)))
        XCTAssertThrowsError(try ProviderMessage(id: "large", role: .user, content: String(repeating: "🚀", count: 262_145)))
        let message = try ProviderMessage(id: "m", role: .user, content: "")
        XCTAssertThrowsError(try NativeConversationEnvelope(conversationID: "many", binding: localProfile().binding, messages: Array(repeating: message, count: 1_025)))
        let docs = try (0..<33).map { try ProviderDocument(name: "doc-\($0)", text: "") }
        XCTAssertThrowsError(try ProviderMessage(id: "docs", role: .user, content: "", documents: docs))
        let calls = try (0..<129).map { try ProviderToolCall(id: "call-\($0)", name: "tool", argumentsJSON: "{}") }
        XCTAssertThrowsError(try ProviderMessage(id: "tools", role: .assistant, content: "", toolCalls: calls))
        let commands = try (0..<129).map { try PendingRemoteCommand(requestID: "request-\($0)", kind: .send) }
        XCTAssertThrowsError(try session(commands: commands))
        XCTAssertThrowsError(try approval(expiry: 9_007_199_254_740_992))
    }

    func testRawJSONPreflightBoundsContainerEntriesAndPrimitiveDepth() throws {
        let oversized = Data(("[" + Array(repeating: "0", count: 1_025).joined(separator: ",") + "]").utf8)
        XCTAssertThrowsError(try NativeStrictJSON.validate(oversized))
        let boundary = Data((String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31)).utf8)
        XCTAssertNoThrow(try NativeStrictJSON.validate(boundary))
        let tooDeep = Data((String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)).utf8)
        XCTAssertThrowsError(try NativeStrictJSON.validate(tooDeep))
    }
}
