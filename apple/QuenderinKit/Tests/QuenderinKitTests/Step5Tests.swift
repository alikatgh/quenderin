import XCTest
@testable import QuenderinKit

private final class Step5FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, host = url.host!
        let handshake = "{\"protocol\":1,\"modelRevision\":\"\(Step5Contract.modelRevision)\",\"backendRevision\":\"\(Step5Contract.backendRevision)\",\"artifactsVerified\":true,\"ready\":true,\"maxOutputTokens\":1024,\"maxConcurrentRequests\":1}"
        let data: Data
        if url.path == "/quenderin/step5" { data = Data(handshake.utf8) }
        else if host == "private.invalid" { data = Data("{\"text\":\"<think>fixture private</think>\",\"truncated\":false}".utf8) }
        else if host == "large.invalid" { data = Data(repeating: 65, count: 307_201) }
        else { data = Data("{\"text\":\"Fixture final answer\",\"truncated\":false}".utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        if host == "slow.invalid" { return }
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class Step5Tests: XCTestCase {
    private func client() -> Step5Client { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [Step5FixtureProtocol.self]; return Step5Client(configuration: configuration) }
    func testEndpointMessageAndAnswerBounds() throws {
        for endpoint in ["http://127.0.0.1:18000", "http://[::1]:18000", "https://cuda.example"] { XCTAssertNoThrow(try Step5Contract.endpoint(endpoint)) }
        for endpoint in ["http://localhost:18000", "http://192.168.1.2", "https://user:pass@host", "https://host/path", "https://host/?token=x", "https://host/#x", "file:///private/tmp/model"] { XCTAssertThrowsError(try Step5Contract.endpoint(endpoint)) }
        XCTAssertThrowsError(try Step5Contract.messages([Step5Message(role: "assistant", content: "bad")]))
        XCTAssertThrowsError(try Step5Contract.messages([Step5Message(role: "user", content: String(repeating: "é", count: 4097))]))
        for output in ["{\"text\":\"x\",\"text\":\"y\",\"truncated\":false}", "{\"text\":\"x\",\"truncated\":false} trailing", "{\"text\":{},\"truncated\":false}", "{\"text\":\"<|im_start|>analysis\",\"truncated\":false}"] { XCTAssertThrowsError(try Step5Contract.answer(Data(output.utf8))) }
    }
    func testActualSessionProtocolAndBoundedFinalAnswer() async throws {
        let client = client()
        try await client.check("https://fixture.invalid")
        let answer = try await client.answer("https://fixture.invalid", messages: [Step5Message(role: "user", content: "Test fixture prompt")])
        XCTAssertEqual(answer.text, "Fixture final answer")
        for endpoint in ["https://private.invalid", "https://large.invalid"] {
            do { _ = try await client.answer(endpoint, messages: [Step5Message(role: "user", content: "Test fixture prompt")]); XCTFail("Invalid answer accepted") } catch {}
        }
    }
    func testConcurrentRequestRejectedAndCancellationStopsSession() async throws {
        let client = client(), pending = Task { try await client.check("https://slow.invalid") }
        try await Task.sleep(nanoseconds: 50_000_000)
        do { try await client.check("https://fixture.invalid"); XCTFail("Concurrent request accepted") } catch {}
        await client.cancel()
        do { try await pending.value; XCTFail("Cancelled request succeeded") } catch {}
    }
    @MainActor func testControllerPreservesFailedPromptAndAppendsOnlyValidRetry() async throws {
        let controller = Step5Controller(client: client())
        controller.endpoint = "https://private.invalid"; controller.consent = true; controller.prompt = "Keep this fixture prompt"
        controller.send()
        for _ in 0..<200 where controller.busy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(controller.busy); XCTAssertNotNil(controller.failure)
        XCTAssertEqual(controller.prompt, "Keep this fixture prompt"); XCTAssertTrue(controller.messages.isEmpty)
        controller.endpoint = "https://fixture.invalid"
        XCTAssertFalse(controller.consent)
        controller.consent = true; controller.send()
        for _ in 0..<200 where controller.busy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(controller.busy); XCTAssertNil(controller.failure)
        XCTAssertEqual(controller.messages.count, 2); XCTAssertEqual(controller.prompt, "")
        for exchange in 2...8 {
            controller.prompt = "Synthetic exchange \(exchange)"; controller.send()
            for _ in 0..<200 where controller.busy { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertFalse(controller.busy); XCTAssertNil(controller.failure)
        }
        XCTAssertEqual(controller.messages.count, 16)
        controller.prompt = "Synthetic ninth exchange"; controller.send()
        XCTAssertFalse(controller.busy); XCTAssertNotNil(controller.failure)
        XCTAssertEqual(controller.messages.count, 16); XCTAssertEqual(controller.prompt, "Synthetic ninth exchange")
    }
}
