import XCTest
@testable import QuenderinKit

/// Pins the recents policy for agent goals (`AgentGoalHistory`) — kept in behavioral lockstep
/// with the Kotlin twin's CoreVerify checks.
final class AgentGoalHistoryTests: XCTestCase {

    func testRecordInsertsNewestFirst() {
        var list = AgentGoalHistory.record("first goal", at: 1, into: [])
        list = AgentGoalHistory.record("second goal", at: 2, into: list)
        XCTAssertEqual(list.map(\.goal), ["second goal", "first goal"])
    }

    func testRecordTrimsAndIgnoresEmpty() {
        let list = AgentGoalHistory.record("  padded goal \n", at: 1, into: [])
        XCTAssertEqual(list.map(\.goal), ["padded goal"])
        XCTAssertEqual(AgentGoalHistory.record("   \n ", at: 2, into: list), list)
    }

    func testReRunMovesToTopWithoutDuplicating() {
        var list = AgentGoalHistory.record("a", at: 1, into: [])
        list = AgentGoalHistory.record("b", at: 2, into: list)
        list = AgentGoalHistory.record("a", at: 3, into: list)   // re-used
        XCTAssertEqual(list.map(\.goal), ["a", "b"])             // moved up, not duplicated
        XCTAssertEqual(list[0].lastUsedAt, 3)                    // timestamp refreshed
    }

    func testDedupIsCaseSensitiveByDesign() {
        // Case-insensitive dedup needs a locale-neutral casefold on BOTH platforms (Turkish
        // dotless-i) — the exact twin-drift class seam-normalization eliminated. Exact match only.
        var list = AgentGoalHistory.record("Convert 5 miles", at: 1, into: [])
        list = AgentGoalHistory.record("convert 5 miles", at: 2, into: list)
        XCTAssertEqual(list.count, 2)
    }

    func testCapDropsOldest() {
        var list: [AgentGoalEntry] = []
        for i in 0..<(AgentGoalHistory.maxEntries + 5) {
            list = AgentGoalHistory.record("goal \(i)", at: Int64(i), into: list)
        }
        XCTAssertEqual(list.count, AgentGoalHistory.maxEntries)
        XCTAssertEqual(list.first?.goal, "goal \(AgentGoalHistory.maxEntries + 4)")   // newest kept
        XCTAssertEqual(list.last?.goal, "goal 5")                                     // oldest 5 dropped
    }

    func testRemove() {
        var list = AgentGoalHistory.record("keep", at: 1, into: [])
        list = AgentGoalHistory.record("drop", at: 2, into: list)
        XCTAssertEqual(AgentGoalHistory.remove("drop", from: list).map(\.goal), ["keep"])
    }

    func testEncodeDecodeRoundtrip() throws {
        var list = AgentGoalHistory.record("roundtrip me", at: 42, into: [])
        list = AgentGoalHistory.record("and me", at: 43, into: list)
        let decoded = AgentGoalHistory.decode(try AgentGoalHistory.encode(list))
        XCTAssertEqual(decoded, list)
    }

    func testDecodeOfEmptyOrCorruptBlobIsEmptyHistoryNotError() {
        XCTAssertEqual(AgentGoalHistory.decode(Data()), [])
        XCTAssertEqual(AgentGoalHistory.decode(Data("not json{{".utf8)), [])
    }

    @MainActor
    func testStorePersistsAcrossInstances() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AgentGoalHistoryStore(directory: dir)
        store.record("persist me")
        store.record("me too")

        let reloaded = AgentGoalHistoryStore(directory: dir)   // fresh instance = app relaunch
        XCTAssertEqual(reloaded.entries.map(\.goal), ["me too", "persist me"])

        reloaded.clear()
        XCTAssertEqual(AgentGoalHistoryStore(directory: dir).entries, [])
    }
}
