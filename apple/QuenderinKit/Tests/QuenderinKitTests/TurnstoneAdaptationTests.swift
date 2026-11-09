import XCTest
@testable import QuenderinKit

@MainActor
final class TurnstoneAdaptationTests: XCTestCase {
    func testExplicitModelHold() {
        // adapt:model-hold-recommend
        if case .recommend = ModelSelectionHold.decide(explicitModelId: "  ", availability: .missing, evidence: .ordinary) {} else {
            XCTFail("blank id recommends")
        }
        // adapt:model-hold-missing
        guard case .wait(_, _, let missing) = ModelSelectionHold.decide(explicitModelId: "qwen3-4b", availability: .missing, evidence: .ordinary) else {
            return XCTFail("missing waits")
        }
        XCTAssertEqual(missing, "\"qwen3-4b\" is not on this device. This choice stays selected and was not replaced. Choose another model to continue.")
        // adapt:model-hold-unreadable
        guard case .wait(_, _, let unreadable) = ModelSelectionHold.decide(explicitModelId: "gone", availability: .unreadable, evidence: .ordinary) else {
            return XCTFail("unreadable waits")
        }
        XCTAssertTrue(unreadable.contains("cannot be read"))
        XCTAssertTrue(unreadable.contains("was not replaced"))
        // adapt:model-hold-incompatible
        guard case .wait(_, _, let incompatible) = ModelSelectionHold.decide(explicitModelId: "qwen3-4b", availability: .incompatible, evidence: .ordinary) else {
            return XCTFail("incompatible waits")
        }
        XCTAssertTrue(incompatible.contains("does not run in this build"))
        // adapt:model-hold-blocked
        guard case .wait(_, _, let blocked) = ModelSelectionHold.decide(explicitModelId: "bonsai2-27b", availability: .blocked, evidence: .experimentalSource) else {
            return XCTFail("blocked waits")
        }
        XCTAssertTrue(blocked.contains("does not fit the current memory gate"))
        XCTAssertTrue(blocked.contains(ModelSelectionHold.experimentalSourceNotice))
        // adapt:model-hold-experimental-notice
        guard case .use(_, _, let notice) = ModelSelectionHold.decide(explicitModelId: "bonsai2-27b", availability: .present, evidence: .experimentalSource) else {
            return XCTFail("experimental use")
        }
        XCTAssertEqual(notice, ModelSelectionHold.experimentalSourceNotice)
        guard case .use(_, _, let ordinary) = ModelSelectionHold.decide(explicitModelId: "qwen3-4b", availability: .present, evidence: .ordinary) else {
            return XCTFail("ordinary use")
        }
        XCTAssertEqual(ordinary, "")
    }

    func testNamedGuidance() {
        let notes = GuidanceNotebook()
        // adapt:guidance-select-only
        XCTAssertEqual(notes.save(name: "Packing", text: "Use {{model}} for {{other}}"), .ok)
        XCTAssertNil(notes.render(modelLabel: "Qwen3 4B"))
        if case .rejected = notes.select(name: "Missing") {} else { XCTFail("unknown name is rejected") }
        // adapt:guidance-one-active
        XCTAssertEqual(notes.save(name: "Travel", text: "Short answers."), .ok)
        XCTAssertEqual(notes.select(name: "Packing"), .ok)
        XCTAssertEqual(notes.select(name: "Travel"), .ok)
        let travel = notes.render(modelLabel: "Qwen3 4B") ?? ""
        XCTAssertTrue(travel.contains("Short answers."))
        XCTAssertFalse(travel.contains("{{model}}"))
        // adapt:guidance-placeholder
        XCTAssertEqual(notes.select(name: "Packing"), .ok)
        let rendered = notes.render(modelLabel: "Qwen3 4B") ?? ""
        XCTAssertTrue(rendered.contains("Use Qwen3 4B for {{other}}"))
        // adapt:guidance-no-model-knob
        XCTAssertTrue(rendered.contains("does not change the model or which tools can run"))
        XCTAssertFalse(rendered.contains("temperature"))
        if case .rejected = notes.save(name: "", text: "x") {} else { XCTFail("empty name rejected") }
    }

    func testConversationWriter() {
        let writers = ConversationWriter()
        // adapt:writer-one-owner
        guard case .granted(let first) = writers.claim(conversationId: "chat-1", writerId: "writer-a", nowMs: 1_000, ttlMs: 500) else {
            return XCTFail("first claim")
        }
        guard case .busy(_, let busy) = writers.claim(conversationId: "chat-1", writerId: "writer-b", nowMs: 1_200, ttlMs: 500) else {
            return XCTFail("second claim waits")
        }
        XCTAssertEqual(busy, "This conversation already has a live reply from \"writer-a\". Wait for it to finish.")
        XCTAssertTrue(writers.release(first, nowMs: 1_200))
        // adapt:writer-expiry
        guard case .granted(let expired) = writers.claim(conversationId: "chat-1", writerId: "writer-a", nowMs: 2_000, ttlMs: 100) else {
            return XCTFail("expired owner")
        }
        guard case .granted(let recovered) = writers.claim(conversationId: "chat-1", writerId: "writer-c", nowMs: 2_100, ttlMs: 100) else {
            return XCTFail("recovered owner")
        }
        XCTAssertEqual(recovered.writerId, "writer-c")
        // adapt:writer-stale-release
        XCTAssertFalse(writers.release(expired, nowMs: 2_100))
        var forged = recovered
        forged = WriterPermit(conversationId: recovered.conversationId, writerId: recovered.writerId, token: "other", expiresAtMs: recovered.expiresAtMs)
        XCTAssertFalse(writers.release(forged, nowMs: 2_100))
        XCTAssertTrue(writers.release(recovered, nowMs: 2_100))
    }

    func testSecondChatWriterDoesNotAppend() async {
        let writers = ConversationWriter()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        _ = writers.claim(conversationId: "same", writerId: "other-screen", nowMs: now, ttlMs: 60_000)
        let chat = ChatModel(engine: MockInferenceEngine(cannedReply: "ok"))
        chat.writers = writers
        chat.conversationKey = "same"
        await chat.send("hello")
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertTrue(chat.preparationError?.contains("live reply") == true)
    }

    func testSelectedGuidanceReachesTheChatPrompt() async {
        let engine = RecordingEngine()
        let chat = ChatModel(engine: engine)
        XCTAssertEqual(chat.guidance.save(name: "Packing", text: "Use {{model}} for {{other}}"), .ok)
        XCTAssertEqual(chat.guidance.select(name: "Packing"), .ok)
        let model = ModelCatalog.smallest
        await chat.send("hello", model: model)
        let system = await engine.system ?? ""
        XCTAssertTrue(system.contains("Use \(model.label) for {{other}}"))
        XCTAssertTrue(system.contains("does not change the model or which tools can run"))
    }

    func testManualMissingModelIsNotReplaced() async {
        let suite = "turnstone-hold-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AutomaticModelPreferences(defaults: defaults)
        prefs.chooseManually(ModelCatalog.smallest.id)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("turnstone-hold-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let onboarding = OnboardingModel(
            downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir,
            recallActiveModelID: { nil }, rememberActiveModelID: { _ in }, automaticPreferences: prefs
        )
        await onboarding.start()
        guard case .failed(let reason) = onboarding.phase else {
            return XCTFail("manual missing model stays failed, got \(onboarding.phase)")
        }
        XCTAssertTrue(reason.contains("is not on this device"))
        XCTAssertTrue(reason.contains("was not replaced"))
    }
}

private actor RecordingEngine: InferenceEngine {
    private(set) var system: String?
    func loadedModelID() async -> String? { "loaded" }
    func load(model: ModelEntry, at fileURL: URL) async throws {}
    func unload() async {}
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        self.system = system
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}
