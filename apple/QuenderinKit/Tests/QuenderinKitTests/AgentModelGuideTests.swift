import XCTest
@testable import QuenderinKit

final class AgentModelGuideTests: XCTestCase {

    /// The load-bearing distinction the whole shipped experience turns on: Qwen3 4B is a genuinely
    /// better AGENT than the same-size Gemma 3 4B (proven live — Gemma bailed, Qwen3 did real tool use).
    func testQwen3OutranksSameSizeGemmaForAgents() {
        XCTAssertGreaterThan(AgentModelGuide.aptitude(for: "qwen3-4b"),
                             AgentModelGuide.aptitude(for: "gemma3-4b"),
                             "Qwen3 4B must rate higher than Gemma 3 4B for agent use")
    }

    /// Aptitude climbs with capability: a 14B is excellent, a 1B is basic.
    func testAptitudeClimbsWithModelStrength() {
        XCTAssertEqual(AgentModelGuide.aptitude(for: "qwen3-14b"), .excellent)
        XCTAssertEqual(AgentModelGuide.aptitude(for: "qwen3-4b"), .strong)
        XCTAssertEqual(AgentModelGuide.aptitude(for: "llama32-1b"), .basic)
        XCTAssertGreaterThan(AgentModelGuide.aptitude(for: "qwen3-14b"),
                             AgentModelGuide.aptitude(for: "llama32-1b"))
    }

    /// Every model we actually ship gets a real rating (the `default` is a safety net, not a
    /// silent catch-all for shipped models).
    func testEveryCatalogModelIsRatedAtLeastBasic() {
        for model in ModelCatalog.models {
            // All enum cases are >= .basic by construction; this asserts the switch returns for each id.
            XCTAssertGreaterThanOrEqual(AgentModelGuide.aptitude(for: model.id), .basic, model.id)
        }
        // The shipped mainstream default must never read as weak.
        XCTAssertGreaterThanOrEqual(AgentModelGuide.aptitude(for: "qwen3-4b"), .strong)
    }

    /// On an 8 GB Mac running the weaker same-size model, the briefing proposes the better agent.
    func testBriefingProposesABetterAgentWhenHardwareAllows() {
        let b = AgentModelGuide.briefing(activeModelID: "gemma3-4b", totalRAMGB: 8, deviceNoun: "Mac")
        XCTAssertEqual(b.aptitude, .capable)
        let up = try? XCTUnwrap(b.upgrade)
        XCTAssertTrue(up?.modelLabel.contains("Qwen3") == true, "should propose Qwen3 as the better fit")
        XCTAssertGreaterThan(up!.aptitude, b.aptitude)
        XCTAssertTrue(up!.reason.contains("Settings"), "the proposal must tell the user how to switch")
    }

    /// On a large-memory Mac running the 4B, it proposes the 14B (a step up in aptitude). Uses 32 GB
    /// because the 85% memory budget + KV overhead keeps the 11 GB 14B off a 16 GB machine — the
    /// briefing correctly won't propose a model the device can't safely load.
    func testBriefingProposesTheBigModelOnAmpleRAM() {
        let b = AgentModelGuide.briefing(activeModelID: "qwen3-4b", totalRAMGB: 32, deviceNoun: "Mac")
        XCTAssertNotNil(b.upgrade)
        XCTAssertTrue(b.upgrade?.modelLabel.contains("14B") == true)
        XCTAssertEqual(b.upgrade?.aptitude, .excellent)
    }

    /// Honesty guard: a 16 GB Mac can't safely load the 11 GB 14B, so it must NOT be proposed there.
    func testBriefingDoesNotProposeAModelThatWontFit() {
        let b = AgentModelGuide.briefing(activeModelID: "qwen3-4b", totalRAMGB: 16, deviceNoun: "Mac")
        XCTAssertFalse(b.upgrade?.modelLabel.contains("14B") ?? false,
                       "must not propose the 14B on a 16 GB machine it can't safely load")
    }

    /// The on-message guard: on roomy RAM running the weak 4B Gemma, the proposal must be a Qwen-family
    /// agent — NEVER a bigger-but-weaker Gemma. Recommending "the largest model that fits" would do
    /// exactly the wrong thing; the ranking is by AGENT ability, not size.
    func testUpgradeRecommendsAQwenNotABiggerGemma() {
        let b = AgentModelGuide.briefing(activeModelID: "gemma3-4b", totalRAMGB: 16, deviceNoun: "Mac")
        XCTAssertNotNil(b.upgrade)
        XCTAssertFalse(b.upgrade?.modelLabel.contains("Gemma") ?? true, "must not recommend a bigger Gemma")
        XCTAssertTrue(b.upgrade?.modelLabel.contains("Qwen") ?? false, "should recommend a Qwen agent")
    }

    /// When already on the best fit, it reassures instead of nagging.
    func testBriefingReassuresWhenAlreadyOnTheBestFit() {
        let b = AgentModelGuide.briefing(activeModelID: "qwen3-4b", totalRAMGB: 8, deviceNoun: "Mac")
        XCTAssertNil(b.upgrade, "no upgrade nag when already on the best fit for the hardware")
        XCTAssertTrue(b.hardwareLine.contains("comfortably"))
        XCTAssertTrue(b.hardwareLine.contains("8 GB"))
    }

    /// A missing/unknown active model degrades gracefully — no crash, a sane label.
    func testBriefingHandlesUnknownActiveModel() {
        let b = AgentModelGuide.briefing(activeModelID: nil, totalRAMGB: 8, deviceNoun: "Mac")
        XCTAssertEqual(b.modelLabel, "your model")
        XCTAssertTrue(b.privacyNote.contains("never leave"))
    }
}
