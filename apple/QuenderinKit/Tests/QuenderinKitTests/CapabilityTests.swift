import XCTest
@testable import QuenderinKit

/// The Capability abstraction (AGENT_AUTONOMY_PLAN Milestone 0, step 2). Twin of the Kotlin
/// CoreVerify "Capability abstraction" checks — keep the two in sync.
final class CapabilityTests: XCTestCase {

    func testShippedToolsAreT0PureCompute() async throws {
        let tools: [Capability] = [EchoTool(), CalculatorTool(), UnitConverterTool(), DateCalcTool()]
        for tool in tools {
            XCTAssertEqual(tool.tier, .pureCompute, "\(tool.name) should be T0")
            XCTAssertEqual(tool.blastRadius, .none, "\(tool.name) should have no blast radius")
            XCTAssertFalse(tool.requiresConsent, "\(tool.name) should not require consent")
            let preview = try await tool.plan("anything")
            XCTAssertFalse(preview.mutates, "\(tool.name) preview should not mutate")
        }
    }

    func testTierIsOrderedByRisk() {
        XCTAssertLessThan(CapabilityTier.pureCompute, .readOnly)
        XCTAssertLessThan(CapabilityTier.readOnly, .irreversible)
    }

    func testBlastRadiusMutates() {
        XCTAssertFalse(BlastRadius.none.mutates)
        XCTAssertFalse(BlastRadius.read(resource: "f").mutates)
        XCTAssertTrue(BlastRadius.write(resource: "f").mutates)
        XCTAssertTrue(BlastRadius.irreversible(resource: "f").mutates)
    }

    func testGateAllowsCleanT0Run() async throws {
        let decision = try await CapabilityGate.assess(CalculatorTool(), input: "2 + 2", isConsented: false)
        guard case .allowed = decision else { return XCTFail("clean T0 run should be allowed, got \(decision)") }
    }

    func testGateBlocksBlocklistInputBeforeRunning() async throws {
        let decision = try await CapabilityGate.assess(CalculatorTool(), input: "delete everything then pay", isConsented: true)
        guard case .blocked(let keyword) = decision else { return XCTFail("blocklist input should be blocked, got \(decision)") }
        XCTAssertTrue(["delete", "pay"].contains(keyword))
    }

    func testGateDemandsConsentForT1UntilGranted() async throws {
        // Synthetic T1 capability — the real fs.read lands in Milestone 0 step 3.
        struct TestRead: Capability {
            let name = "test.read"
            let purpose = "read a file (test)"
            let tier: CapabilityTier = .readOnly
            let blastRadius: BlastRadius = .read(resource: "a file")
            func plan(_ input: String) async throws -> ActionPreview { ActionPreview(summary: "would read \(input)", mutates: false) }
            func run(_ input: String) async throws -> String { "contents of \(input)" }
        }
        let denied = try await CapabilityGate.assess(TestRead(), input: "notes.txt", isConsented: false)
        guard case .needsConsent(let preview) = denied else { return XCTFail("T1 without consent should need consent, got \(denied)") }
        XCTAssertFalse(preview.mutates)

        let allowed = try await CapabilityGate.assess(TestRead(), input: "notes.txt", isConsented: true)
        guard case .allowed = allowed else { return XCTFail("T1 with consent should be allowed, got \(allowed)") }
    }
}
