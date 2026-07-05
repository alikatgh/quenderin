import XCTest
@testable import QuenderinKit

/// Milestone 3: plan preview — several steps, ONE approval. Twin of the Kotlin CoreVerify
/// "plan execution" checks (the parser cases live in AgentParityTests, parity-vectored).
final class PlanExecutionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) throws {
        try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testPlanOfTwoMovesRunsWithOneApproval() async throws {
        try makeFile("a.txt"); try makeFile("b.txt")
        let journal = UndoJournal()
        let move = FileMoveCapability(workspace: { [root] in root }, journal: journal)
        let consent = InMemoryConsentStore(); consent.setGranted("fs.move", true)
        let ledger = InMemoryAuditLedger()
        let approvals = Counter()
        let runner = CapabilityRunner(consent: consent, ledger: ledger, approve: { preview in
            approvals.increment()
            XCTAssertTrue(preview.summary.contains("1. Move \"a.txt\""))
            XCTAssertTrue(preview.summary.contains("2. Move \"b.txt\""))
            return true
        })

        let out = await runner.executePlan([(move, "a.txt to Archive"), (move, "b.txt to Archive")])
        XCTAssertEqual(approvals.value, 1, "ONE approval for the whole plan")
        XCTAssertTrue(out.contains("1. Moved") && out.contains("2. Moved"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/b.txt").path))
        XCTAssertEqual(ledger.entries().map(\.decision), ["allowed", "allowed"])
        XCTAssertEqual(journal.count, 2, "each step individually undoable")
    }

    func testDeclinedPlanChangesNothingAndBlockedStepRefusesPreApproval() async throws {
        try makeFile("a.txt")
        let move = FileMoveCapability(workspace: { [root] in root }, journal: UndoJournal())
        let consent = InMemoryConsentStore(); consent.setGranted("fs.move", true)
        let asked = Counter()

        let declining = CapabilityRunner(consent: consent, approve: { _ in asked.increment(); return false })
        let declined = await declining.executePlan([(move, "a.txt to Archive")])
        XCTAssertTrue(declined.contains("You declined the plan"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

        let blocking = CapabilityRunner(consent: consent, approve: { _ in asked.increment(); return true })
        let blocked = await blocking.executePlan([(move, "a.txt to Archive"), (move, "delete everything to Trash")])
        XCTAssertTrue(blocked.contains("blocked action"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path),
                      "a plan with a blocked step does NOTHING")
        XCTAssertEqual(asked.value, 1, "the blocked plan never reached approval")
    }

    func testAgentLoopExecutesScriptedPlanEndToEnd() async throws {
        try makeFile("a.txt")
        let move = FileMoveCapability(workspace: { [root] in root }, journal: UndoJournal())
        let consent = InMemoryConsentStore(); consent.setGranted("fs.move", true)
        let engine = ScriptedInferenceEngine(replies: [
            #"{"plan":[{"tool":"fs.move","input":"a.txt to Archive"}]}"#,
            #"{"answer":"organized"}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [move],
                             runner: CapabilityRunner(consent: consent, approve: { _ in true }))
        let run = await loop.run(goal: "organize")
        XCTAssertEqual(run.answer, "organized")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/a.txt").path))
    }

    /// A tiny thread-safe counter (the approve closure is @Sendable).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
}
