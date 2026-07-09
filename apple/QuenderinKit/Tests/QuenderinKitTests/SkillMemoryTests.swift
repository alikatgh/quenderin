import XCTest
@testable import QuenderinKit

/// The reliability-compounding loop — record proven tool sequences, recall them for similar goals.
/// Twin of the desktop `SkillMemory` (src/) + the Kotlin twin: same tokenization + similarity + caps.
final class SkillMemoryTests: XCTestCase {

    func testRecordsAndRecallsASimilarGoal() {
        var m = SkillMemory()
        m.record(goal: "organize my downloads folder", tools: ["fs.list", "fs.move"])
        let hits = m.recall(goal: "please organize the downloads folder now")
        XCTAssertEqual(hits.first?.tools, ["fs.list", "fs.move"])
    }

    func testDissimilarGoalIsNotRecalled() {
        var m = SkillMemory()
        m.record(goal: "draft an email to my boss", tools: ["mac.mail.draft"])
        XCTAssertTrue(m.recall(goal: "what is the capital of France").isEmpty, "unrelated goal must not prime")
    }

    func testDedupesAGoalKeepingTheMostRecentSequence() {
        var m = SkillMemory()
        m.record(goal: "tidy desktop", tools: ["fs.list"])
        m.record(goal: "tidy desktop", tools: ["fs.list", "fs.move", "mac.finder.reveal"])
        XCTAssertEqual(m.size, 1, "an identical goal de-dupes")
        XCTAssertEqual(m.recall(goal: "tidy desktop").first?.tools, ["fs.list", "fs.move", "mac.finder.reveal"])
    }

    func testIgnoresEmptyRuns() {
        var m = SkillMemory()
        m.record(goal: "", tools: ["x"])
        m.record(goal: "real goal", tools: [])
        XCTAssertEqual(m.size, 0)
    }

    func testCapacityDropsOldestFirst() {
        var m = SkillMemory(capacity: 2)
        m.record(goal: "goal one alpha", tools: ["a"])
        m.record(goal: "goal two bravo", tools: ["b"])
        m.record(goal: "goal three charlie", tools: ["c"])
        XCTAssertEqual(m.size, 2)
        XCTAssertTrue(m.recall(goal: "goal one alpha").isEmpty, "the oldest was evicted")
    }

    func testSnapshotRestoreRoundTripsAndRecaps() {
        var m = SkillMemory()
        m.record(goal: "find and open my report", tools: ["fs.list", "mac.finder.reveal", "mac.app.open"])
        var m2 = SkillMemory()
        m2.restore(m.snapshot())
        XCTAssertEqual(m2.recall(goal: "find and open the report").first?.tools,
                       ["fs.list", "mac.finder.reveal", "mac.app.open"])
        // restore caps a poisoned row (Q-280): an over-long goal + over-many tools are bounded.
        var m3 = SkillMemory()
        m3.restore([SkillRecord(goal: String(repeating: "x", count: 500),
                                tools: (0..<60).map { "t\($0)" })])
        let restored = m3.snapshot().first
        XCTAssertLessThanOrEqual(restored?.goal.count ?? 999, SkillMemory.maxGoalLen)
        XCTAssertLessThanOrEqual(restored?.tools.count ?? 999, SkillMemory.maxTools)
    }

    // The parity-sensitive primitives — must match the TS/Kotlin twins exactly.
    func testTokenizationIsAsciiWordCharsLongerThanTwo() {
        XCTAssertEqual(SkillMemory.tokens("Organize my Downloads-folder!"),
                       ["organize", "downloads", "folder"])   // "my" dropped (len 2); split on non-[a-z0-9]
    }

    func testSimilarityIsOverlapCoefficient() {
        XCTAssertEqual(SkillMemory.similarity(["abc", "def"], ["abc", "xyz"]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SkillMemory.similarity([], ["abc"]), 0, accuracy: 0.0001)
        // subset → 1.0 (min denominator)
        XCTAssertEqual(SkillMemory.similarity(["abc"], ["abc", "def", "ghi"]), 1.0, accuracy: 0.0001)
    }
}
