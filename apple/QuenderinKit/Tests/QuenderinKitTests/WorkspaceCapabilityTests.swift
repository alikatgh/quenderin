import XCTest
@testable import QuenderinKit

/// Milestone 2: the workspace — fs.list (T1), fs.move (T2, the FIRST write), the undo journal,
/// and the runner's fail-closed per-run approval. Twin of the Kotlin CoreVerify checks.
final class WorkspaceCapabilityTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, _ contents: String = "x") throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: fs.list

    func testListShowsWorkspaceAndNothingWithoutGrant() async throws {
        try makeFile("b.txt"); try makeFile("a.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: false)

        let list = FileListCapability(workspace: { [root] in root })
        let out = try await list.run("")
        XCTAssertEqual(out, "a.txt\nb.txt\nsub/")

        let ungranted = FileListCapability(workspace: { nil })
        let refused = try await ungranted.run("")
        XCTAssertTrue(refused.contains("No workspace folder granted"))
    }

    // MARK: fs.move

    func testMoveMovesRecordsUndoAndUndoRestores() async throws {
        try makeFile("report.pdf", "REPORT")
        let journal = UndoJournal()
        let move = FileMoveCapability(workspace: { [root] in root }, journal: journal)

        let out = try await move.run("report.pdf to Archive")
        XCTAssertTrue(out.contains("Moved \"report.pdf\" into \"Archive/\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/report.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path))
        XCTAssertEqual(journal.count, 1)

        let undo = journal.undoLast()
        XCTAssertTrue(undo.contains("back to where it was"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path))
        XCTAssertEqual(journal.count, 0)
        XCTAssertEqual(journal.undoLast(), "Nothing to undo.")
    }

    func testMoveNeverOverwritesAndRejectsPaths() async throws {
        try makeFile("report.pdf", "NEW")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archive"), withIntermediateDirectories: false)
        try "OLD".write(to: root.appendingPathComponent("Archive/report.pdf"), atomically: true, encoding: .utf8)
        let move = FileMoveCapability(workspace: { [root] in root }, journal: UndoJournal())

        let collision = try await move.run("report.pdf to Archive")
        XCTAssertTrue(collision.contains("refusing to overwrite"))
        // The original is untouched, the target keeps its OLD contents — zero data loss.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("report.pdf"), encoding: .utf8), "NEW")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Archive/report.pdf"), encoding: .utf8), "OLD")

        // Model-minted paths and traversal are rejected on shape, before any filesystem access.
        for hostile in ["../secret to Archive", "report.pdf to ../outside", "a/b.txt to c"] {
            let refused = try await move.run(hostile)
            XCTAssertTrue(refused.contains("paths aren't allowed") || refused.contains("Input must be"),
                          "\"\(hostile)\" must be rejected, got: \(refused)")
        }
    }

    // MARK: per-run approval (the write gate)

    func testMutatingCapabilityFailsClosedWithoutApprover() async throws {
        try makeFile("report.pdf")
        let move = FileMoveCapability(workspace: { [root] in root }, journal: UndoJournal())
        let consent = InMemoryConsentStore()
        consent.setGranted("fs.move", true)   // standing consent alone is NOT enough for a write
        let ledger = InMemoryAuditLedger()
        let runner = CapabilityRunner(consent: consent, ledger: ledger)   // no approver wired

        let out = await runner.execute(move, input: "report.pdf to Archive")
        // Assert the exact prefix AgentLoop.isPermissionRefusal keys on, so this test guards the
        // runtime halt contract — not just arbitrary copy (the reason it broke when the copy moved).
        XCTAssertTrue(out.hasPrefix("This would change something on your Mac"),
                      "fail-closed must return the recognizable per-run-approval refusal, got: \(out)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path),
                      "fail-closed means the file did NOT move")
        XCTAssertEqual(ledger.entries().last?.decision, "needsApproval")
    }

    func testApprovalDeclinedAndGrantedPaths() async throws {
        try makeFile("report.pdf")
        let move = FileMoveCapability(workspace: { [root] in root }, journal: UndoJournal())
        let consent = InMemoryConsentStore()
        consent.setGranted("fs.move", true)
        let ledger = InMemoryAuditLedger()

        let declining = CapabilityRunner(consent: consent, ledger: ledger, approve: { _ in false })
        let declined = await declining.execute(move, input: "report.pdf to Archive")
        XCTAssertTrue(declined.contains("You declined"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path))

        let approving = CapabilityRunner(consent: consent, ledger: ledger, approve: { preview in
            XCTAssertTrue(preview.mutates)
            XCTAssertTrue(preview.summary.contains("Move \"report.pdf\""))
            return true
        })
        let moved = await approving.execute(move, input: "report.pdf to Archive")
        XCTAssertTrue(moved.contains("Moved"))
        XCTAssertEqual(ledger.entries().map(\.decision), ["declined", "allowed"])
    }

    func testReadOnlyCapabilityNeedsNoApprover() async throws {
        try makeFile("a.txt")
        let list = FileListCapability(workspace: { [root] in root })
        let consent = InMemoryConsentStore()
        consent.setGranted("fs.list", true)
        let runner = CapabilityRunner(consent: consent)   // no approver — fine for reads
        let out = await runner.execute(list, input: "")
        XCTAssertEqual(out, "a.txt")
    }
}
