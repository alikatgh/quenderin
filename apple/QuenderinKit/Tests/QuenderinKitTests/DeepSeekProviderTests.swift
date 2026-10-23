import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
@testable import QuenderinKit

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    private enum Mismatch: Error { case fixture }
    private func sharedFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/" + name)
    }
    private func fixtures(_ category: String) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sharedFile("deepseek-provider-fixtures.json"))) as? [String: Any])
        return try XCTUnwrap(root[category] as? [[String: Any]])
    }
    private func require(_ condition: Bool, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else { XCTFail("DeepSeek fixture mismatch: " + id, file: file, line: line); throw Mismatch.fixture }
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func request(_ fixture: [String: Any]) throws -> ProviderRequest {
        let codec = NativeConversationCodec()
        let profile = try codec.decodeProfile(json(XCTUnwrap(fixture["profile"])))
        let envelope = try codec.decodeEnvelope(json(XCTUnwrap(fixture["envelope"])))
        let tools = try JSONDecoder().decode([ProviderToolDefinition].self, from: json(XCTUnwrap(fixture["tools"])))
        let raw = try XCTUnwrap(fixture["limits"] as? [String: Any])
        let limits = try ProviderRequestLimits(maxOutputTokens: XCTUnwrap((raw["maxOutputTokens"] as? NSNumber)?.int64Value),
            maxToolCalls: XCTUnwrap(raw["maxToolCalls"] as? Int), deadlineEpochMs: XCTUnwrap((raw["deadlineEpochMs"] as? NSNumber)?.int64Value))
        return try ProviderRequest(requestID: "fixture", profile: profile, envelope: envelope,
            capabilities: DeepSeekContract.capabilities, tools: tools, limits: limits, nowEpochMs: 1)
    }
    func testCanonicalRequestsPreserveStructuredMessages() throws {
        for fixture in try fixtures("requests") {
            let id = try XCTUnwrap(fixture["id"] as? String)
            if fixture["error"] != nil {
                var rejected = false
                do { _ = try DeepSeekContract.body(request(fixture)) } catch { rejected = true }
                try require(rejected, id)
            } else {
                let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: DeepSeekContract.body(request(fixture))) as? NSDictionary)
                try require(actual.isEqual(to: XCTUnwrap(fixture["expectedBody"] as? [String: Any])), id)
            }
            print("DEEPSEEK_FIXTURE_PASS " + id)
        }
    }
    func testCanonicalIncrementalStreams() throws {
        for fixture in try fixtures("streams") {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let chunks = try XCTUnwrap(fixture["chunksBase64"] as? [String])
            var decoder = DeepSeekSSEDecoder()
            var accumulator = DeepSeekStreamAccumulator(maxToolCalls: try XCTUnwrap(fixture["maxToolCalls"] as? Int))
            var rejected = false
            do {
                for chunk in chunks {
                    for event in try decoder.append(XCTUnwrap(Data(base64Encoded: chunk))) {
                        _ = try accumulator.accept(event, messageID: "assistant")
                    }
                }
                try decoder.finish(); try accumulator.finish()
            } catch { rejected = true }
            if fixture["error"] != nil { try require(rejected, id) }
            else {
                try require(!rejected, id)
                let expected = try XCTUnwrap(fixture["expected"] as? [String: Any])
                try require(accumulator.text == expected["text"] as? String, id)
                try require(accumulator.reasoning == expected["reasoning"] as? String, id)
                try require(accumulator.finishReason?.rawValue == expected["finish"] as? String, id)
                let calls = accumulator.toolCalls.enumerated().map { index, call in
                    ["index": index, "id": call.id, "name": call.name, "arguments": call.argumentsJSON] as [String: Any]
                }
                try require((calls as NSArray).isEqual(to: XCTUnwrap(expected["toolCalls"] as? [Any])), id)
                if let usage = expected["usage"] as? [String: Int] {
                    try require(accumulator.usage?.inputTokens == usage["inputTokens"].map(Int64.init), id)
                    try require(accumulator.usage?.outputTokens == usage["outputTokens"].map(Int64.init), id)
                } else { try require(accumulator.usage == nil, id) }
            }
            print("DEEPSEEK_FIXTURE_PASS " + id)
        }
    }
    func testCanonicalModelValidation() throws {
        for fixture in try fixtures("models") {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let data = Data(try XCTUnwrap(fixture["json"] as? String).utf8)
            if fixture["error"] != nil {
                var rejected = false
                do { _ = try DeepSeekContract.modelIDs(data, selected: "deepseek-flash") } catch { rejected = true }
                try require(rejected, id)
            } else {
                try require(try DeepSeekContract.modelIDs(data, selected: "deepseek-flash") == XCTUnwrap(fixture["expectedIDs"] as? [String]), id)
            }
            print("DEEPSEEK_FIXTURE_PASS " + id)
        }
    }
    func testReviewedCatalogAndLimitsMatchSharedContract() throws {
        let contract = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sharedFile("deepseek-provider-contract.json"))) as? [String: Any])
        XCTAssertEqual(contract["catalogVersion"] as? String, DeepSeekContract.catalogVersion)
        XCTAssertEqual(contract["origin"] as? String, DeepSeekContract.origin)
        XCTAssertEqual((contract["models"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, DeepSeekContract.models)
        let limits = try XCTUnwrap(contract["limits"] as? [String: Int])
        XCTAssertEqual(limits["deadlineMs"], Int(DeepSeekContract.seconds * 1_000))
        XCTAssertEqual(limits["maxRequestBytes"], DeepSeekContract.maxBytes)
        XCTAssertEqual(limits["maxResponseBytes"], DeepSeekContract.maxBytes)
        XCTAssertEqual(limits["maxSSEEventBytes"], DeepSeekContract.maxEventBytes)
        XCTAssertEqual(limits["maxSSEEvents"], DeepSeekContract.maxEvents)
        XCTAssertEqual(limits["defaultMaxOutputTokens"], Int(DeepSeekContract.maxTokens))
    }
    func testResponseBoundsDuplicateKeysAndMalformedToolFieldsFailClosed() throws {
        var decoder = DeepSeekSSEDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: DeepSeekContract.maxEventBytes + 1)))
        var frames = DeepSeekSSEDecoder()
        XCTAssertThrowsError(try frames.append(Data(String(repeating: ": keepalive\n\n", count: DeepSeekContract.maxEvents + 1).utf8)))
        var accumulator = DeepSeekStreamAccumulator(maxToolCalls: 1)
        XCTAssertThrowsError(try accumulator.accept("{\"choices\":[],\"choices\":[]}", messageID: "a"))
        let malformed = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":42,"function":{"name":"x","arguments":"{}"}}]},"finish_reason":null}]}"#
        XCTAssertThrowsError(try accumulator.accept(malformed, messageID: "a"))
        let oversized = #"{"choices":[{"index":0,"delta":{"content":""# + String(repeating: "a", count: DeepSeekContract.maxEventBytes + 1) + #""},"finish_reason":null}]}"#
        XCTAssertThrowsError(try accumulator.accept(oversized, messageID: "a"))
        XCTAssertThrowsError(try DeepSeekContract.modelIDs(Data(#"{"data":[],"data":[]}"#.utf8), selected: "deepseek-flash"))
    }
    func testDiagnosticsHideKeysAndWireContent() throws {
        let key = try DeepSeekAPIKey("not-a-real-key")
        let call = DeepSeekHTTPCall(path: "/models", body: Data("private-content".utf8), key: key, timeout: 30)
        for value in [String(describing: key), String(reflecting: key), String(describing: call), String(reflecting: call), String(reflecting: DeepSeekHTTPEvent.bytes(Data("private-content".utf8)))] {
            XCTAssertFalse(value.contains("not-a-real-key")); XCTAssertFalse(value.contains("private-content"))
        }
        XCTAssertEqual(Mirror(reflecting: key).children.count, 0)
        XCTAssertEqual(Mirror(reflecting: call).children.count, 0)
    }
    func testSessionConfigurationAndAllRedirectsDeniedWithoutNetwork() async throws {
        let configuration = DeepSeekURLSessionTransport.secureConfiguration(timeout: 12)
        XCTAssertNil(configuration.httpCookieStorage); XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache); XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 12)
        for target in ["https://api.deepseek.com/other", "https://other.example/chat", "http://api.deepseek.com/chat"] {
            let pair = AsyncThrowingStream<DeepSeekHTTPEvent, Error>.makeStream()
            let url = try XCTUnwrap(URL(string: "https://api.deepseek.com/chat/completions"))
            let delegate = DeepSeekSessionDelegate(url: url, continuation: pair.continuation)
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: url) // Never resumed; no network request.
            var allowed = true
            delegate.urlSession(session, task: task,
                willPerformHTTPRedirection: try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)),
                newRequest: URLRequest(url: try XCTUnwrap(URL(string: target)))) { allowed = $0 != nil }
            XCTAssertFalse(allowed)
            do { for try await _ in pair.stream {} ; XCTFail("A redirect must fail") }
            catch { XCTAssertEqual(error as? DeepSeekFailure, .rejected) }
            session.invalidateAndCancel()
        }
    }
    func testHTTPFailuresAreFixedAndNeverRetry() async throws {
        for (status, expected) in [(401, DeepSeekFailure.unauthorized), (402, .quota), (429, .rateLimited), (413, .contextLimit), (400, .rejected)] {
            let transport = ScriptedDeepSeekTransport(events: [.response(status: status, url: URL(string: DeepSeekContract.origin + "/models")!, contentType: "application/json"), .bytes(Data("sensitive-provider-error".utf8))])
            let client = DeepSeekClient(transport: transport)
            do { _ = try await client.validate(key: DeepSeekAPIKey("not-a-real-key"), selectedModel: "deepseek-flash"); XCTFail("Must reject") }
            catch { XCTAssertEqual(error as? DeepSeekFailure, expected); XCTAssertFalse(error.localizedDescription.contains("sensitive-provider-error")) }
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }
    func testCrossOriginResponseIsRejectedBeforeBody() async throws {
        let transport = ScriptedDeepSeekTransport(events: [.response(status: 200, url: URL(string: "https://other.example/models")!, contentType: "application/json"), .bytes(Data(#"{"data":[{"id":"deepseek-flash"}]}"#.utf8))])
        do { _ = try await DeepSeekClient(transport: transport).validate(key: DeepSeekAPIKey("not-a-real-key"), selectedModel: "deepseek-flash"); XCTFail("Must reject") }
        catch { XCTAssertEqual(error as? DeepSeekFailure, .rejected) }
    }
    func testKeychainIdentityExcludesMutableAccessibility() throws {
        #if canImport(Security)
        let identity = try DeepSeekKeychainStore().identity("qcred:" + UUID().uuidString)
        XCTAssertNil(identity[kSecAttrAccessible as String])
        XCTAssertEqual(identity[kSecAttrService as String] as? String, "org.quenderin.deepseek")
        XCTAssertEqual(identity[kSecAttrSynchronizable as String] as? Bool, false)
        #endif
    }
    private func currentRequest(deadlineMs: Int64) throws -> ProviderRequest {
        let fixture = try XCTUnwrap(fixtures("requests").first)
        let prior = try request(fixture)
        let profile = try NativeConversationCodec().decodeProfile(json(XCTUnwrap(fixture["profile"])))
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return try ProviderRequest(requestID: "cancel-fixture", profile: profile, envelope: prior.envelope,
            capabilities: DeepSeekContract.capabilities, tools: [],
            limits: ProviderRequestLimits(maxOutputTokens: 4096, maxToolCalls: 0, deadlineEpochMs: now + deadlineMs), nowEpochMs: now)
    }
    func testCancellationBeforeTransportAdmissionNeverDispatches() async throws {
        let transport = GatedDeepSeekTransport()
        let client = DeepSeekClient(transport: transport)
        let request = try currentRequest(deadlineMs: 120_000)
        let work = Task { try await client.run(request, key: DeepSeekAPIKey("not-a-real-key")) { _ in } }
        for _ in 0..<200 {
            if await transport.entered { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let entered = await transport.entered; XCTAssertTrue(entered)
        work.cancel()
        do { _ = try await work.value; XCTFail("A cancelled admission must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.dispatched
        XCTAssertEqual(count, 0)
    }
    func testDeadlineStopsSilentConnectionWithoutRetry() async throws {
        let transport = ScriptedDeepSeekTransport(events: [], suspended: true)
        let client = DeepSeekClient(transport: transport)
        do { _ = try await client.run(currentRequest(deadlineMs: 30), key: DeepSeekAPIKey("not-a-real-key")) { _ in }; XCTFail("Must time out") }
        catch { XCTAssertEqual(error as? DeepSeekFailure, .timeout) }
        let count = await transport.calls.count; XCTAssertEqual(count, 1)
    }
    func testOldCancellationCannotCancelNewCall() async throws {
        let url = URL(string: DeepSeekContract.origin + "/models")!
        let events: [DeepSeekHTTPEvent] = [.response(status: 200, url: url, contentType: "application/json"), .bytes(Data(#"{"data":[{"id":"deepseek-flash"}]}"#.utf8))]
        let transport = ScriptedDeepSeekTransport(events: events)
        let client = DeepSeekClient(transport: transport)
        let oldID = UUID(); let newID = UUID()
        _ = try await client.validate(key: DeepSeekAPIKey("not-a-real-key"), selectedModel: "deepseek-flash", callID: oldID)
        await transport.set(events: events, suspended: true)
        let work = Task { try await client.validate(key: DeepSeekAPIKey("not-a-real-key"), selectedModel: "deepseek-flash", callID: newID) }
        for _ in 0..<200 {
            if await transport.calls.count == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await client.cancel(callID: oldID)
        await transport.cancel(callID: oldID) // Even a delayed transport cancellation is scoped.
        let activeID = await transport.currentCallID; XCTAssertEqual(activeID, newID)
        await client.cancel(callID: newID)
        do { _ = try await work.value; XCTFail("New call should be cancelled") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor GatedDeepSeekTransport: DeepSeekHTTPTransport {
    var entered = false
    var dispatched = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var cancelled: Set<UUID> = []
    func open(_ call: DeepSeekHTTPCall) async throws -> AsyncThrowingStream<DeepSeekHTTPEvent, Error> {
        entered = true
        await withCheckedContinuation { gate = $0 }
        try Task.checkCancellation()
        guard !cancelled.contains(call.id) else { throw CancellationError() }
        dispatched += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func cancel(callID: UUID) {
        cancelled.insert(callID); gate?.resume(); gate = nil
    }
}

private actor ScriptedDeepSeekTransport: DeepSeekHTTPTransport {
    var events: [DeepSeekHTTPEvent]
    var calls: [DeepSeekHTTPCall] = []
    var suspended: Bool
    var continuation: AsyncThrowingStream<DeepSeekHTTPEvent, Error>.Continuation?
    var currentCallID: UUID?
    init(events: [DeepSeekHTTPEvent], suspended: Bool = false) { self.events = events; self.suspended = suspended }
    func set(events: [DeepSeekHTTPEvent], suspended: Bool = false) { self.events = events; self.suspended = suspended }
    func open(_ call: DeepSeekHTTPCall) -> AsyncThrowingStream<DeepSeekHTTPEvent, Error> {
        calls.append(call)
        currentCallID = call.id
        let pair = AsyncThrowingStream<DeepSeekHTTPEvent, Error>.makeStream()
        continuation = pair.continuation
        events.forEach { pair.continuation.yield($0) }
        if !suspended { pair.continuation.finish() }
        return pair.stream
    }
    func cancel(callID: UUID) {
        guard currentCallID == callID else { return }
        continuation?.finish(throwing: CancellationError()); continuation = nil; currentCallID = nil
    }
}

#if canImport(Combine)
/// Locks protect the synchronous injectable storage protocols; no real Keychain access.
private final class FakeDeepSeekCredentials: DeepSeekCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: DeepSeekAPIKey] = [:]
    private var shouldFail = false
    func fail(_ value: Bool) { lock.withLock { shouldFail = value } }
    func load(reference: String) throws -> DeepSeekAPIKey {
        try lock.withLock { guard !shouldFail, let key = keys[reference] else { throw DeepSeekFailure.credentialStorage }; return key }
    }
    func save(_ key: DeepSeekAPIKey, reference: String) throws {
        try lock.withLock { guard !shouldFail else { throw DeepSeekFailure.credentialStorage }; keys[reference] = key }
    }
    func remove(reference: String) throws {
        try lock.withLock { guard !shouldFail else { throw DeepSeekFailure.credentialStorage }; keys[reference] = nil }
    }
    var count: Int { lock.withLock { keys.count } }
}
private final class FakeDeepSeekJournalStorage: DeepSeekJournalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeepSeekJournal?
    private var shouldFail = false
    private var successfulSavesUntilFailure: Int?
    private var successfulSavesUntilLandedFailure: Int?
    func fail(_ value: Bool) { lock.withLock { shouldFail = value } }
    func failOnce(afterSuccessfulSaves count: Int) { lock.withLock { successfulSavesUntilFailure = count } }
    func landThenThrowOnce(afterSuccessfulSaves count: Int) { lock.withLock { successfulSavesUntilLandedFailure = count } }
    func load() throws -> DeepSeekJournal? { lock.withLock { value } }
    func save(_ journal: DeepSeekJournal) throws {
        try lock.withLock {
            guard !shouldFail else { throw DeepSeekFailure.persistence }
            if let remaining = successfulSavesUntilFailure {
                if remaining == 0 { successfulSavesUntilFailure = nil; throw DeepSeekFailure.persistence }
                successfulSavesUntilFailure = remaining - 1
            }
            if let remaining = successfulSavesUntilLandedFailure {
                if remaining == 0 {
                    successfulSavesUntilLandedFailure = nil; value = journal
                    throw DeepSeekFailure.persistence
                }
                successfulSavesUntilLandedFailure = remaining - 1
            }
            value = journal
        }
    }
}

@MainActor
final class DeepSeekControllerTests: XCTestCase {
    private var modelEvents: [DeepSeekHTTPEvent] {
        [.response(status: 200, url: URL(string: DeepSeekContract.origin + "/models")!, contentType: "application/json"),
         .bytes(Data(#"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#.utf8))]
    }
    private func finishBytes(reason: String = "stop") -> Data {
        Data((#"data: {"choices":[{"index":0,"delta":{"reasoning_content":"thought","content":"answer"},"finish_reason":""# + reason + #""}],"usage":{"prompt_tokens":4,"completion_tokens":2}}"# + "\n\ndata: [DONE]\n\n").utf8)
    }
    private func waitUntilIdle(_ controller: DeepSeekController) async throws {
        for _ in 0..<200 {
            if !controller.isBusy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("DeepSeek fake request did not finish")
    }
    func testSecureSetupChatRelaunchAndNoImplicitLocalTransfer() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let client = DeepSeekClient(transport: transport)
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: client)
        XCTAssertFalse(controller.isConnected)
        await controller.connect("not-a-real-key", selectedModel: "deepseek-flash")
        XCTAssertTrue(controller.isConnected); XCTAssertEqual(controller.chat?.envelope.messages.count, 0)
        var calls = await transport.calls
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].path, "/models"); XCTAssertNil(calls[0].body)
        await transport.set(events: [.response(status: 200, url: URL(string: DeepSeekContract.origin + "/chat/completions")!, contentType: "text/event-stream"), .bytes(finishBytes())])
        controller.send("Only this new cloud message")
        try await waitUntilIdle(controller)
        XCTAssertEqual(controller.chat?.state, .ready)
        XCTAssertEqual(controller.chat?.envelope.messages.map(\.content), ["Only this new cloud message", "answer"])
        XCTAssertEqual(controller.chat?.envelope.messages.last?.reasoningContent, "thought")
        calls = await transport.calls
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls.last?.body)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages[0]["content"] as? String, "Only this new cloud message")
        XCTAssertNil(body["tools"])
        let saved = try JSONEncoder().encode(XCTUnwrap(storage.load()))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("not-a-real-key"))
        let relaunched = DeepSeekController(credentials: credentials, storage: storage, client: client)
        XCTAssertEqual(relaunched.chat?.envelope.messages.count, 2)
        let before = await transport.calls.count
        await Task.yield()
        let after = await transport.calls.count
        XCTAssertEqual(before, after) // Relaunch does not start a request.
        relaunched.removeConnection(); XCTAssertFalse(relaunched.isConnected)
        XCTAssertEqual(relaunched.chat?.envelope.messages.count, 2)
    }
    func testStorageAndCredentialErrorsStopBeforePaidRequest() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        await controller.connect("not-a-real-key", selectedModel: "deepseek-flash")
        credentials.fail(true); controller.send("do not transmit")
        XCTAssertEqual(controller.error, .credentialStorage)
        credentials.fail(false); storage.fail(true); controller.send("do not transmit")
        XCTAssertEqual(controller.error, .persistence)
        let count = await transport.calls.count
        XCTAssertEqual(count, 1)
    }
    func testStopRetainsPartialButNeverPromotesOrResubmitsTurn() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        await controller.connect("not-a-real-key", selectedModel: "deepseek-flash")
        let partial = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n".utf8)
        await transport.set(events: [.response(status: 200, url: URL(string: DeepSeekContract.origin + "/chat/completions")!, contentType: "text/event-stream"), .bytes(partial)], suspended: true)
        controller.send("cloud only")
        for _ in 0..<200 {
            if controller.chat?.partialAssistant?.content == "partial" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(controller.chat?.partialAssistant?.content, "partial")
        controller.send("duplicate") // Busy guard.
        controller.stop(); try await waitUntilIdle(controller)
        XCTAssertEqual(controller.chat?.state, .cancelled)
        XCTAssertEqual(controller.chat?.envelope.messages.count, 0)
        XCTAssertEqual(controller.chat?.partialAssistant?.content, "partial")
        XCTAssertFalse(controller.canSend)
        controller.send("must not resend")
        var count = await transport.calls.count
        XCTAssertEqual(count, 2)
        controller.newChat(); XCTAssertEqual(controller.chat?.envelope.messages.count, 0)
        count = await transport.calls.count; XCTAssertEqual(count, 2)
    }
    func testOutputLimitAndInterruptedRelaunchAreNotCompletedHistory() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        await controller.connect("not-a-real-key", selectedModel: "deepseek-flash")
        await transport.set(events: [.response(status: 200, url: URL(string: DeepSeekContract.origin + "/chat/completions")!, contentType: "text/event-stream"), .bytes(finishBytes(reason: "length"))])
        controller.send("limited"); try await waitUntilIdle(controller)
        XCTAssertEqual(controller.chat?.state, .outputLimit); XCTAssertFalse(controller.canSend)
        XCTAssertEqual(controller.chat?.envelope.messages.count, 0)
        var saved = try XCTUnwrap(storage.load()); saved.chats[0].state = .running
        try storage.save(saved)
        let relaunched = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        XCTAssertEqual(relaunched.chat?.state, .interrupted)
        XCTAssertFalse(relaunched.canSend); XCTAssertEqual(relaunched.chat?.envelope.messages.count, 0)
        let count = await transport.calls.count; XCTAssertEqual(count, 2)
    }
    func testCredentialReplacementAndRemovalSurviveJournalCommitFailure() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        await controller.connect("previous-valid-key", selectedModel: "deepseek-flash")
        let previous = try XCTUnwrap(controller.journal.profile?.credentialReference)
        storage.failOnce(afterSuccessfulSaves: 1) // Prepared reference succeeds; new profile commit fails.
        await controller.connect("replacement-key", selectedModel: "deepseek-flash")
        XCTAssertEqual(controller.error, .persistence)
        XCTAssertEqual(controller.journal.profile?.credentialReference, previous)
        XCTAssertEqual(try credentials.load(reference: previous).value, "previous-valid-key")
        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(controller.journal.pendingCredentialRemovals, [])
        storage.failOnce(afterSuccessfulSaves: 0)
        controller.removeConnection()
        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(try credentials.load(reference: previous).value, "previous-valid-key")
        controller.removeConnection()
        XCTAssertFalse(controller.isConnected); XCTAssertEqual(credentials.count, 0)
    }
    func testFailedKeyRemovalRemainsDurablyOwnedAndRecoversOnRelaunch() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        await controller.connect("not-a-real-key", selectedModel: "deepseek-flash")
        let reference = try XCTUnwrap(controller.journal.profile?.credentialReference)
        credentials.fail(true); controller.removeConnection()
        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(try storage.load()?.pendingCredentialRemovals, [reference])
        XCTAssertEqual(controller.error, .credentialStorage)
        credentials.fail(false)
        let relaunched = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        XCTAssertFalse(relaunched.isConnected); XCTAssertEqual(credentials.count, 0)
        XCTAssertEqual(relaunched.journal.pendingCredentialRemovals, [])
        let count = await transport.calls.count; XCTAssertEqual(count, 1)
    }
    func testReportedFailureAfterCommitNeverDeletesDurablyReferencedKey() async throws {
        let transport = ScriptedDeepSeekTransport(events: modelEvents)
        let credentials = FakeDeepSeekCredentials(); let storage = FakeDeepSeekJournalStorage()
        let controller = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        await controller.connect("previous-valid-key", selectedModel: "deepseek-flash")
        let previous = try XCTUnwrap(controller.journal.profile?.credentialReference)
        storage.landThenThrowOnce(afterSuccessfulSaves: 1)
        await controller.connect("replacement-key", selectedModel: "deepseek-flash")
        let replacement = try XCTUnwrap(controller.journal.profile?.credentialReference)
        XCTAssertNotEqual(replacement, previous)
        XCTAssertEqual(try credentials.load(reference: replacement).value, "replacement-key")
        XCTAssertEqual(credentials.count, 1)
        let relaunched = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        XCTAssertEqual(relaunched.journal.profile?.credentialReference, replacement)
        XCTAssertEqual(try credentials.load(reference: replacement).value, "replacement-key")
        storage.landThenThrowOnce(afterSuccessfulSaves: 0)
        relaunched.removeConnection()
        XCTAssertFalse(relaunched.isConnected)
        // An uncertain removal preserves the key until durable pending cleanup is retried.
        XCTAssertEqual(credentials.count, 1)
        let recovered = DeepSeekController(credentials: credentials, storage: storage, client: DeepSeekClient(transport: transport))
        XCTAssertFalse(recovered.isConnected); XCTAssertEqual(credentials.count, 0)
    }
}
#endif
