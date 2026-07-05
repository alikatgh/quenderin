import XCTest
import os
@testable import QuenderinKit

/// Pins the Stop/cancel fixes (Q-005/Q-217/Q-223): stopping generation and switching models must
/// actually tell the engine to interrupt its native decode, not just flip a Swift-side flag.
@MainActor
final class StopCancelTests: XCTestCase {

    func testStopGeneratingRequestsEngineCancel() async {
        let engine = CancelTrackingEngine()
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        let chat = ChatModel(engine: engine)

        // Kick off a generation, then stop it. Stop must call requestCancel() so the native decode
        // is interrupted (mid-prefill included) rather than only breaking at the next token boundary.
        let task = Task { await chat.send("hello") }
        while chat.messages.count < 2 { await Task.yield() }
        chat.stopGenerating()
        await task.value

        XCTAssertGreaterThanOrEqual(engine.cancelCount, 1,
                                    "stopGenerating() must call engine.requestCancel() (Q-005/Q-217)")
    }

    func testInstallRequestsCancelBeforeLoad() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = CancelTrackingEngine()
        let model = OnboardingModel(downloader: MockModelDownloader(), engine: engine, modelsDir: dir,
                                    availableDiskBytes: { _ in .max })

        await model.install(ModelCatalog.smallest)

        XCTAssertGreaterThanOrEqual(engine.cancelCount, 1,
                                    "install() must requestCancel() before load(), like Android (Q-223)")
        XCTAssertTrue(engine.cancelBeforeLoad,
                      "the cancel must land BEFORE load() frees the context")
    }
}

/// An engine that records requestCancel() calls (and whether the first one preceded load()), so a
/// test can assert the Stop/switch paths actually interrupt the engine. Cancel state is held in a
/// synchronous lock (mirroring LlamaEngine's `OSAllocatedUnfairLock`) so `nonisolated
/// requestCancel()` records without an async hop — the real engine's contract, and race-free.
private final class CancelTrackingEngine: InferenceEngine, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (cancels: 0, loaded: false, beforeLoad: false))
    private let loadedID = OSAllocatedUnfairLock<String?>(initialState: nil)

    var cancelCount: Int { state.withLock { $0.cancels } }
    var cancelBeforeLoad: Bool { state.withLock { $0.beforeLoad } }

    func loadedModelID() async -> String? { loadedID.withLock { $0 } }

    func load(model: ModelEntry, at fileURL: URL) async throws {
        state.withLock { if $0.cancels > 0 { $0.beforeLoad = true }; $0.loaded = true }
        loadedID.withLock { $0 = model.id }
    }

    func unload() async { loadedID.withLock { $0 = nil }; state.withLock { $0.loaded = false } }

    func requestCancel() { state.withLock { $0.cancels += 1 } }

    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loadedID.withLock({ $0 }) != nil else { throw InferenceError.modelNotLoaded }
        return AsyncThrowingStream { continuation in
            // Stream slowly so the test can request a stop mid-flight.
            Task {
                for word in ["one", "two", "three", "four", "five"] {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continuation.yield(word + " ")
                }
                continuation.finish()
            }
        }
    }
}
