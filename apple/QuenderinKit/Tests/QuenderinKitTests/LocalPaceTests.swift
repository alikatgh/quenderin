import XCTest
@testable import QuenderinKit

final class LocalPaceTests: XCTestCase {
    func testAMissingOrOffToolDoesNotRun() {
        let suite = "local-pace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LocalPace.admits("  ", defaults: defaults))
        XCTAssertTrue(LocalPace.admits("calculator", defaults: defaults))
        LocalPace.setOn("calculator", false, defaults: defaults)
        XCTAssertFalse(LocalPace.admits("calculator", defaults: defaults))
        XCTAssertTrue(LocalPace.admits("units", defaults: defaults))
        XCTAssertEqual(LocalPace.present("2 + 2 = 4"), "2 + 2 = 4")
        XCTAssertEqual(LocalPace.present("delete everything then pay"), LocalPace.withheld)
        XCTAssertFalse(LocalPace.staysHere.contains("http"))
        XCTAssertTrue(LocalPace.practiceLine.contains("does not test the model"))
        XCTAssertEqual(LocalPace.statusLine(firstUserText: nil, badge: "on-device · private"), "on-device · private")
        XCTAssertTrue(LocalPace.statusLine(firstUserText: "Pack the bag", badge: "on-device · private").hasPrefix("Pack the bag"))
    }

    func testPracticeQuestionsDoNotNeedAModel() async {
        let passed = await LocalPace.practiceOk()
        XCTAssertTrue(passed)
    }
}
