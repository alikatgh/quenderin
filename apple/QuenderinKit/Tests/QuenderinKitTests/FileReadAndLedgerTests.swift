import XCTest
@testable import QuenderinKit

/// Milestone 0 steps 3+4: the fs.read T1 capability, the audit ledger, and the runner that
/// enforces gate → run → ledger. Twin of the Kotlin CoreVerify "fs.read / ledger" checks.
final class FileReadAndLedgerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: fs.read

    func testReadsOnlyGrantedFilesByName() async throws {
        let url = try write("notes.txt", "the elf plans locally")
        let secret = try write("secret.txt", "should be unreachable")
        let cap = FileReadCapability(grantedFiles: { ["notes.txt": url] })

        let granted = try await cap.run("notes.txt")
        XCTAssertEqual(granted, "the elf plans locally")

        // The model can NAME files, never mint paths: an ungranted name — even one that exists
        // on disk, even as an absolute path — resolves to nothing.
        let denied = try await cap.run("secret.txt")
        XCTAssertTrue(denied.contains("No attached file"), "ungranted name must not read: \(denied)")
        let pathDenied = try await cap.run(secret.path)
        XCTAssertTrue(pathDenied.contains("No attached file"), "a raw path must not read: \(pathDenied)")
    }

    func testCaseInsensitiveNameButNoFuzzyMatch() async throws {
        let url = try write("Report.md", "# q")
        let cap = FileReadCapability(grantedFiles: { ["Report.md": url] })
        let ok = try await cap.run("report.md")
        XCTAssertEqual(ok, "# q")
        let fuzzy = try await cap.run("Report")   // prefix ≠ name — predictable, not clever
        XCTAssertTrue(fuzzy.contains("No attached file"))
    }

    func testTruncatesAtMaxBytesAndRejectsNonUTF8() async throws {
        let big = try write("big.txt", String(repeating: "a", count: 5000))
        let cap = FileReadCapability(grantedFiles: { ["big.txt": big] }, maxBytes: 1024)
        let out = try await cap.run("big.txt")
        XCTAssertTrue(out.contains("[…truncated at 1 KB]"))
        XCTAssertLessThan(out.count, 1200)

        let binURL = tempDir.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: binURL)
        let binCap = FileReadCapability(grantedFiles: { ["blob.bin": binURL] })
        let bin = try await binCap.run("blob.bin")
        XCTAssertTrue(bin.contains("isn't a text file"))
    }

    func testPlanPreviewsWithoutReading() async throws {
        let url = try write("notes.txt", "contents")
        let cap = FileReadCapability(grantedFiles: { ["notes.txt": url] })
        let preview = try await cap.plan("notes.txt")
        XCTAssertTrue(preview.summary.contains("Would read"))
        XCTAssertFalse(preview.mutates)
        XCTAssertFalse(preview.summary.contains("contents"), "plan must not leak file contents")
    }

    // MARK: runner + ledger

    func testRunnerEnforcesConsentAndLedgersEverything() async throws {
        let url = try write("notes.txt", "hello")
        let cap = FileReadCapability(grantedFiles: { ["notes.txt": url] })
        let consent = InMemoryConsentStore()
        let ledger = InMemoryAuditLedger()
        let runner = CapabilityRunner(consent: consent, ledger: ledger, now: { Date(timeIntervalSince1970: 0) })

        // T1 without a grant → refused, ledgered as needsConsent, file NOT read.
        let refused = await runner.execute(cap, input: "notes.txt")
        XCTAssertTrue(refused.contains("Needs your permission"))

        // Granted → runs, ledgered as allowed.
        consent.setGranted("fs.read", true)
        let allowed = await runner.execute(cap, input: "notes.txt")
        XCTAssertEqual(allowed, "hello")

        // Blocklist input → refused even WITH consent granted.
        let blocked = await runner.execute(cap, input: "delete notes.txt")
        XCTAssertTrue(blocked.contains("Refused"))

        let decisions = ledger.entries().map(\.decision)
        XCTAssertEqual(decisions, ["needsConsent", "allowed", "blocked(delete)"])
        XCTAssertEqual(ledger.entries()[1].outcome, "hello")
        XCTAssertNil(ledger.entries()[0].outcome, "a refused action has no outcome")
    }

    func testAgentLoopRoutesCapabilitiesThroughRunnerLedger() async throws {
        // A scripted planner calls the calculator (T0) then answers — the ledger must record it.
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"2 + 2"}"#,
            #"{"answer":"4"}"#,
        ])
        let ledger = InMemoryAuditLedger()
        let loop = AgentLoop(engine: engine, tools: [CalculatorTool()],
                             runner: CapabilityRunner(ledger: ledger))
        let run = await loop.run(goal: "add")
        XCTAssertEqual(run.answer, "4")
        XCTAssertEqual(ledger.entries().count, 1)
        XCTAssertEqual(ledger.entries()[0].capability, "calculator")
        XCTAssertEqual(ledger.entries()[0].decision, "allowed")
    }

    func testFileLedgerAppendsAndSurvivesTornTail() throws {
        let url = tempDir.appendingPathComponent("ledger.jsonl")
        let ledger = FileAuditLedger(url: url)
        ledger.append(AuditEntry(timestamp: Date(timeIntervalSince1970: 1), capability: "fs.read",
                                 tier: 1, input: "a", decision: "allowed", outcome: "x"))
        ledger.append(AuditEntry(timestamp: Date(timeIntervalSince1970: 2), capability: "fs.read",
                                 tier: 1, input: "b", decision: "blocked(pay)", outcome: nil))
        // Simulate a crash mid-append: a torn, half-written last line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":\"2026-".utf8))
        try handle.close()

        let read = FileAuditLedger(url: url).entries()
        XCTAssertEqual(read.count, 2, "torn tail is skipped, prior entries survive")
        XCTAssertEqual(read[1].decision, "blocked(pay)")
    }
}
