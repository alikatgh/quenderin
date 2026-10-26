import XCTest
import Foundation
@testable import QuenderinKit

/// Engine-side ChatCapStatus contract. ChatModel wiring is deliberately out of scope; these tests
/// pin the declared reasons, the no-circular default, the measured native mapping, automatic model
/// transactions, legacy booleans, and suspension/stale publication.
final class ChatCapStatusTests: XCTestCase {

    private actor CapFake: InferenceEngine {
        private var status: ChatCapStatus
        private let pieces: [String]
        private var loaded: String? = "cap-fake"
        private var failLoad = false

        init(status: ChatCapStatus, pieces: [String] = []) {
            self.status = status
            self.pieces = pieces
        }

        func loadedModelID() async -> String? { loaded }
        func load(model: ModelEntry, at fileURL: URL) async throws {
            if failLoad { throw InferenceError.loadFailed(reason: "fixture load failure") }
            loaded = model.id
        }
        func unload() async { loaded = nil }
        func chatCapStatus() async -> ChatCapStatus { status }
        func setStatus(_ status: ChatCapStatus) { self.status = status }
        func setFailLoad(_ fail: Bool) { failLoad = fail }

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            let pieces = self.pieces
            return AsyncThrowingStream { continuation in
                for piece in pieces { continuation.yield(piece) }
                continuation.finish()
            }
        }
    }

    /// Leaves one stream open until `finish()` so a suspension can invalidate its publication.
    private actor GatedCapFake: InferenceEngine {
        private var status: ChatCapStatus = .hit
        private var loaded: String? = "gated"
        private var continuation: AsyncThrowingStream<String, Error>.Continuation?
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var started = false

        func loadedModelID() async -> String? { loaded }
        func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
        func unload() async { loaded = nil }
        nonisolated func requestCancel() {}
        func chatCapStatus() async -> ChatCapStatus { status }

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                self.continuation = continuation
                continuation.yield("piece")
                if let waiter = startedWaiter {
                    startedWaiter = nil
                    waiter.resume()
                } else {
                    started = true
                }
            }
        }

        func waitUntilStarted() async {
            if started { started = false; return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        func finish() {
            continuation?.finish()
            continuation = nil
        }
    }

    /// Native completion is done; return its latched HIT only when the test releases the gate.
    private actor StatusGatedCapFake: InferenceEngine {
        nonisolated let statusEntered = XCTestExpectation(description: "wrapper status read suspended")
        nonisolated let cancelEntered = XCTestExpectation(description: "underlying cancellation requested")
        private var statusWaiter: CheckedContinuation<ChatCapStatus, Never>?
        private var released = false

        func loadedModelID() async -> String? { "status-gated" }
        func load(model: ModelEntry, at fileURL: URL) async throws {}
        func unload() async {}
        nonisolated func requestCancel() { cancelEntered.fulfill() }
        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func chatCapStatus() async -> ChatCapStatus {
            if released { return .hit }
            return await withCheckedContinuation {
                statusWaiter = $0
                statusEntered.fulfill()
            }
        }
        func releaseStatus() {
            released = true
            statusWaiter?.resume(returning: .hit)
            statusWaiter = nil
        }
    }

    /// The forwarding Task inherits this task local. Its release joins that task even when
    /// cancellation has already ended the consumer's iterator, without a scheduler delay.
    private final class CapTaskLifetime: Sendable {
        let finished: XCTestExpectation
        init(_ finished: XCTestExpectation) { self.finished = finished }
        deinit { finished.fulfill() }
    }
    private enum CapTaskScope {
        @TaskLocal static var lifetime: CapTaskLifetime?
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tinyModel(in dir: URL, id: String) throws -> ModelEntry {
        let filename = "\(id).gguf"
        let file = dir.appendingPathComponent(filename)
        try Data("GGUFtiny-\(id)".utf8).write(to: file)
        return ModelEntry(
            id: id, label: id, filename: filename, ramGB: 1, sizeLabel: "tiny fixture",
            paramsBillions: 1, quantization: "Q4_K_M", urlString: "",
            sha256: try ModelIntegrity.sha256Hex(of: file)
        )
    }

    func testDefaultStatusIsUnknown() async {
        let mock = MockInferenceEngine()
        let status = await mock.chatCapStatus()
        XCTAssertEqual(status, .unknown)
    }

    func testObservedHitIsIndependentOfChunkCount() async throws {
        let zero = CapFake(status: .hit)
        let few = CapFake(status: .hit, pieces: ["a", "b"])

        let zeroStream = try await zero.generateChat(system: "", history: [], options: .init())
        for try await _ in zeroStream {}
        let fewStream = try await few.generateChat(system: "", history: [], options: .init())
        for try await _ in fewStream {}

        let zeroStatus = await zero.chatCapStatus()
        let fewStatus = await few.chatCapStatus()
        XCTAssertEqual(zeroStatus, .hit, "zero chunks do not prove NOT_HIT")
        XCTAssertEqual(fewStatus, .hit)
    }

    func testObservedNotHitDespiteManyChunks() async throws {
        let many = CapFake(status: .notHit, pieces: Array(repeating: "x", count: 300))
        let stream = try await many.generateChat(system: "", history: [], options: .init())
        for try await _ in stream {}

        let status = await many.chatCapStatus()
        XCTAssertEqual(status, .notHit)
    }

    func testNativeMappingDistinguishesBudgetFromEogContextAndUnknown() {
        XCTAssertEqual(LlamaEngine.capStatus(for: .budget), .hit)
        XCTAssertEqual(LlamaEngine.capStatus(for: .eog), .notHit)
        XCTAssertEqual(LlamaEngine.capStatus(for: .contextExhausted), .notHit)
        XCTAssertEqual(LlamaEngine.capStatus(for: .cancelled), .unknown)
        XCTAssertEqual(LlamaEngine.capStatus(for: .unavailable), .unknown)
    }

    func testExplicitCancellationDuringStatusReadCannotRepublishHit() async throws {
        let underlying = StatusGatedCapFake()
        let wrapper = CoordinatedInferenceEngine(underlying)
        let stream = try await wrapper.generateChat(system: "", history: [], options: .init())
        let finished = XCTestExpectation(description: "wrapper forwarding settled")
        let consume = Task {
            defer { finished.fulfill() }
            for try await _ in stream {}
        }
        let entered = await XCTWaiter.fulfillment(of: [underlying.statusEntered], timeout: 5)
        guard entered == .completed else {
            await underlying.releaseStatus()
            consume.cancel()
            XCTFail("wrapper must reach the status gate")
            return
        }
        wrapper.requestCancel()
        let canceled = await XCTWaiter.fulfillment(of: [underlying.cancelEntered], timeout: 5)
        XCTAssertEqual(canceled, .completed)
        let during = await wrapper.chatCapStatus()
        XCTAssertEqual(during, .unknown)
        await underlying.releaseStatus()
        let settled = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(settled, .completed)
        consume.cancel()
        guard settled == .completed else { return }
        try await consume.value
        let after = await wrapper.chatCapStatus()
        XCTAssertEqual(after, .unknown, "the latched HIT belongs to a canceled run")
    }

    func testConsumerCancellationDuringStatusReadCannotPublishHit() async throws {
        let underlying = StatusGatedCapFake()
        let wrapper = CoordinatedInferenceEngine(underlying)
        let forwardingFinished = XCTestExpectation(description: "consumer and forwarding task released")
        let consumerFinished = XCTestExpectation(description: "canceled consumer settled")
        let consume = Task {
            defer { consumerFinished.fulfill() }
            try await CapTaskScope.$lifetime.withValue(CapTaskLifetime(forwardingFinished)) {
                let stream = try await wrapper.generateChat(system: "", history: [], options: .init())
                for try await _ in stream {}
            }
        }
        let entered = await XCTWaiter.fulfillment(of: [underlying.statusEntered], timeout: 5)
        guard entered == .completed else {
            consume.cancel()
            await underlying.releaseStatus()
            XCTFail("wrapper must reach the status gate")
            return
        }
        consume.cancel()
        let canceled = await XCTWaiter.fulfillment(of: [consumerFinished], timeout: 5)
        XCTAssertEqual(canceled, .completed)
        await underlying.releaseStatus()
        let settled = await XCTWaiter.fulfillment(of: [forwardingFinished], timeout: 5)
        XCTAssertEqual(settled, .completed)
        guard settled == .completed else { return }
        let after = await wrapper.chatCapStatus()
        XCTAssertEqual(after, .unknown, "consumer cancellation during the status await must suppress HIT")
    }

    func testExplicitCancellationInvalidatesAnAlreadyPublishedHit() async throws {
        let wrapper = CoordinatedInferenceEngine(CapFake(status: .hit))
        let stream = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in stream {}
        let before = await wrapper.chatCapStatus()
        XCTAssertEqual(before, .hit)
        wrapper.requestCancel()
        let after = await wrapper.chatCapStatus()
        XCTAssertEqual(after, .unknown)
    }

    func testSpecialistSuspensionAndRestorationDoNotLeakThePreviousStatus() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try tinyModel(in: dir, id: "tiny-a")
        let underlying = CapFake(status: .hit)
        let wrapper = CoordinatedInferenceEngine(underlying)
        try await wrapper.load(model: model, at: dir.appendingPathComponent(model.filename))
        let first = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in first {}
        let before = await wrapper.chatCapStatus()
        XCTAssertEqual(before, .hit)

        let lease = try await wrapper.suspendForSpecialist()
        let suspended = await wrapper.chatCapStatus()
        XCTAssertEqual(suspended, .unknown)

        try await lease.resume()
        let restored = await wrapper.chatCapStatus()
        XCTAssertEqual(restored, .unknown, "restoration must not leak the prior main status")

        await underlying.setStatus(.notHit)
        let second = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in second {}
        let after = await wrapper.chatCapStatus()
        XCTAssertEqual(after, .notHit)
    }

    func testSuccessiveRunsDoNotRetainThePreviousStatus() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try tinyModel(in: dir, id: "tiny-b")
        let underlying = CapFake(status: .hit)
        let wrapper = CoordinatedInferenceEngine(underlying)
        try await wrapper.load(model: model, at: dir.appendingPathComponent(model.filename))

        let first = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in first {}
        let firstStatus = await wrapper.chatCapStatus()
        XCTAssertEqual(firstStatus, .hit)

        await underlying.setStatus(.unknown)
        let second = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in second {}
        let secondStatus = await wrapper.chatCapStatus()
        XCTAssertEqual(secondStatus, .unknown)
    }

    func testAutomaticModelTransactionInvalidatesPreviousHit() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstModel = try tinyModel(in: dir, id: "auto-a")
        let secondModel = try tinyModel(in: dir, id: "auto-b")
        let underlying = CapFake(status: .hit)
        let wrapper = CoordinatedInferenceEngine(underlying)
        try await wrapper.load(model: firstModel, at: dir.appendingPathComponent(firstModel.filename))
        let first = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in first {}
        let before = await wrapper.chatCapStatus()
        XCTAssertEqual(before, .hit)

        let accepted = try await wrapper.loadForAutomaticIfIdle(
            model: secondModel, at: dir.appendingPathComponent(secondModel.filename),
            stillCurrent: { true }, accept: { true }
        )
        XCTAssertTrue(accepted)
        let afterSuccess = await wrapper.chatCapStatus()
        XCTAssertEqual(afterSuccess, .unknown, "a successful switch must clear the old hit")

        let next = try await wrapper.generateChat(system: "", history: [], options: .init())
        for try await _ in next {}
        let reloaded = await wrapper.chatCapStatus()
        XCTAssertEqual(reloaded, .hit)

        await underlying.setFailLoad(true)
        do {
            _ = try await wrapper.loadForAutomaticIfIdle(
                model: secondModel, at: dir.appendingPathComponent(secondModel.filename),
                stillCurrent: { true }, accept: { true }
            )
            XCTFail("the failed switch must throw")
        } catch {
            // Expected fixture failure; the status must still be invalidated.
        }
        let afterFailure = await wrapper.chatCapStatus()
        XCTAssertEqual(afterFailure, .unknown, "a failed switch must clear the old hit")
    }

    func testStaleCompletionCannotRepublishHitAfterSpecialistInvalidation() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try tinyModel(in: dir, id: "stale-a")
        let underlying = GatedCapFake()
        let wrapper = CoordinatedInferenceEngine(underlying)
        try await wrapper.load(model: model, at: dir.appendingPathComponent(model.filename))

        let consume = Task {
            do {
                let stream = try await wrapper.generateChat(system: "", history: [], options: .init())
                for try await _ in stream {}
            } catch {
                // Cancellation from the suspension is expected.
            }
        }
        await underlying.waitUntilStarted()
        let lease = try await wrapper.suspendForSpecialist()
        let during = await wrapper.chatCapStatus()
        XCTAssertEqual(during, .unknown)

        await underlying.finish()
        await consume.value
        try await lease.resume()

        let after = await wrapper.chatCapStatus()
        XCTAssertEqual(after, .unknown, "stale completion must not republish after restoration")
    }
}
