import XCTest
@testable import QuenderinKit

/// Milestone 0 step 5: the composition the APP actually ships — AgentToolkit + AttachedFilesStore
/// + runner — exercised end to end: attach → refused (no consent) → grant → read → ledger.
final class AgentToolkitTests: XCTestCase {

    func testToolkitShipsFsReadWiredToAttachments() {
        let toolkit = AgentToolkit.standard(attachments: AttachedFilesStore())
        XCTAssertTrue(toolkit.contains { $0.name == "fs.read" })
        XCTAssertEqual(AgentToolkit.capabilities().count, toolkit.count,
                       "everything we ship is a capability — a plain tool would bypass the runner")
    }

    func testAttachedFilesStoreDedupesAndSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("notes.txt")
        try "one".write(to: a, atomically: true, encoding: .utf8)
        let b = dir.appendingPathComponent("sub").appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "two".write(to: b, atomically: true, encoding: .utf8)

        let store = AttachedFilesStore()
        store.attach(a)
        store.attach(b)   // same display name, different file — must not silently replace
        XCTAssertEqual(store.snapshot().count, 2)
        XCTAssertNotNil(store.snapshot()["notes.txt"])
        XCTAssertNotNil(store.snapshot()["notes (2).txt"])

        store.remove("notes.txt")
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testEndToEndAttachConsentReadLedger() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plan.txt")
        try "ship milestone zero".write(to: file, atomically: true, encoding: .utf8)

        let store = AttachedFilesStore()
        store.attach(file)
        let consent = InMemoryConsentStore()
        let ledger = InMemoryAuditLedger()
        let runner = CapabilityRunner(consent: consent, ledger: ledger)

        // The planner asks fs.read for the attached file, twice; consent is granted in between.
        let planner = ScriptedInferenceEngine(replies: [
            #"{"tool":"fs.read","input":"plan.txt"}"#,
            #"{"answer":"blocked run"}"#,
            #"{"tool":"fs.read","input":"plan.txt"}"#,
            #"{"answer":"done"}"#,
        ])
        let loop = AgentLoop(engine: planner, tools: AgentToolkit.standard(attachments: store), runner: runner)

        let refusedRun = await loop.run(goal: "read my plan")
        XCTAssertTrue(refusedRun.steps.contains { $0.observation?.contains("Needs your permission") ?? false },
                      "without a grant the agent is told to ask, not given the file")

        consent.setGranted("fs.read", true)
        let grantedRun = await loop.run(goal: "read my plan")
        XCTAssertTrue(grantedRun.steps.contains { $0.observation?.contains("ship milestone zero") ?? false },
                      "with the grant the agent reads the attached file")

        XCTAssertEqual(ledger.entries().map(\.decision), ["needsConsent", "allowed"])
    }
}
