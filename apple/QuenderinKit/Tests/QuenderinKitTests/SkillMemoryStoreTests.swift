import XCTest
@testable import QuenderinKit

/// Pins the persistent skill-memory edge (UserDefaults store) + pure SkillMemory policy.
final class SkillMemoryStoreTests: XCTestCase {
    func testRecordRecallAndPersistAcrossRelaunch() {
        let suite = "quenderin.skill-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SkillMemoryStore(defaults: defaults)
        store.record(goal: "organize my downloads by type", tools: ["fs.list", "fs.move", "fs.move"])
        store.record(goal: "rename photos by date", tools: ["fs.list", "fs.rename"])

        let hit = store.recall("organize downloads into folders")
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit[0].tools, ["fs.list", "fs.move", "fs.move"])

        // Relaunch from the same defaults reloads the snapshot.
        let reloaded = SkillMemoryStore(defaults: defaults)
        let again = reloaded.recall("organize downloads into folders")
        XCTAssertEqual(again.first?.tools, ["fs.list", "fs.move", "fs.move"])
    }

    func testPurePolicySimilarity() {
        var mem = SkillMemory()
        mem.record(goal: "organize my downloads", tools: ["fs.move"])
        mem.record(goal: "draft an email to bob", tools: ["mac.mail.draft"])
        let hits = mem.recall(goal: "organize downloads folder", k: 2)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].tools, ["fs.move"])
    }
}
