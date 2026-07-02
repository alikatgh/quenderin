import XCTest
@testable import QuenderinKit

/// End-to-end "golden path": the M1 → M2 → M4 pipeline composed on a SINGLE shared
/// engine, the way `QuenderinApp` actually wires it. Each piece is unit-tested in
/// isolation elsewhere; this proves they *compose* — probe → recommend → download →
/// load → chat → agent — with no real model and no device.
@MainActor
final class GoldenPathTests: XCTestCase {

    private func freshDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-golden-\(UUID().uuidString)", isDirectory: true)
    }

    /// probe → recommend → download(mock) → load → chat, all on ONE engine instance.
    func testProbeToChatComposesOnOneEngine() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ONE engine — loaded during onboarding, reused by chat (exactly as QuenderinApp wires it).
        let engine = MockInferenceEngine(cannedReply: "A taut-line hitch holds well.")
        let device = IOSDeviceProfile(
            deviceName: "iPhone 15 Pro", identifier: "iPhone16,1", chip: .a17Pro, totalRAMGB: 8,
            appMemoryBudgetGB: AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: 8),
            freeDiskGB: 128, isKnownDevice: true
        )
        let onboarding = OnboardingModel(
            downloader: MockModelDownloader(), engine: engine, modelsDir: dir, deviceProfile: device,
            availableDiskBytes: { _ in .max }   // deterministic: don't depend on the host's live free disk
        )

        // 1) Probe + recommend — the jetsam-aware selector picks the safe 4B on an 8 GB iPhone.
        let before = await engine.loadedModelID()
        XCTAssertNil(before, "engine starts unloaded")
        await onboarding.start()
        guard case let .recommended(model, hardware, _) = onboarding.phase else {
            return XCTFail("expected .recommended, got \(onboarding.phase)")
        }
        XCTAssertEqual(model.id, "qwen3-4b")
        XCTAssertGreaterThan(hardware.totalRAMGB, 0)
        XCTAssertFalse(onboarding.selection?.alternatives.isEmpty ?? true, "selector surfaces alternatives")

        // 2) Download (mock) → load → ready, into the SAME engine.
        await onboarding.install(model)
        guard case .ready = onboarding.phase else { return XCTFail("expected .ready, got \(onboarding.phase)") }
        let loaded = await engine.loadedModelID()
        XCTAssertEqual(loaded, model.id, "onboarding loaded the recommended model into the shared engine")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.filename).path),
            "the downloader wrote the model file"
        )

        // 3) Chat reuses the onboarding-loaded engine (no reload) and streams a reply.
        let chat = ChatModel(engine: engine)
        await chat.send("What knot for a tarp ridgeline?")
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.last?.text, "A taut-line hitch holds well.",
                       "the assistant reply came from the shared, onboarding-loaded engine")
    }

    /// The agent loop composed with the REAL tool suite + safety gate. The planner is
    /// scripted for determinism; in the app it is the same loaded engine.
    func testAgentStepPlansSafetyGatesAndAnswers() async {
        let tools: [AgentTool] = [CalculatorTool(), UnitConverterTool(), DateCalcTool()]

        // Happy path: plan a tool call → observe the real tool's output → final answer.
        let planner = ScriptedInferenceEngine(replies: [
            #"{"tool":"units","input":"20 km to mi"}"#,
            #"{"answer":"About 12.4 miles."}"#,
        ])
        let run = await AgentLoop(engine: planner, tools: tools).run(goal: "Convert 20 km to miles")
        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertEqual(run.answer, "About 12.4 miles.")
        XCTAssertTrue(run.steps.contains { $0.observation?.contains("12.42") ?? false },
                      "the real UnitConverterTool executed inside the loop")

        // Safety gate: a blocked action is refused before any tool runs.
        let bad = ScriptedInferenceEngine(replies: [#"{"tool":"calculator","input":"delete the files and pay now"}"#])
        let blocked = await AgentLoop(engine: bad, tools: tools).run(goal: "do it")
        XCTAssertEqual(blocked.haltReason, .blocked)
    }
}
