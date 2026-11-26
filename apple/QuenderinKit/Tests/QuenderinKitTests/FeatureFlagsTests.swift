import XCTest
@testable import QuenderinKit

final class FeatureFlagsTests: XCTestCase {
    func testShippedVisionInChatFlagIsOff() {
        XCTAssertFalse(FeatureFlags.visionInChat)
        XCTAssertFalse(
            FeatureFlags.visionInChatAvailable(runtimeAvailable: true, modelInstalled: true)
        )
    }

    func testVisionInChatAvailableTruthTable() {
        let cases: [(flag: Bool, runtime: Bool, installed: Bool, expected: Bool)] = [
            (false, false, false, false),
            (false, false, true, false),
            (false, true, false, false),
            (false, true, true, false),
            (true, false, false, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, true),
        ]
        for row in cases {
            XCTAssertEqual(
                FeatureFlags.visionInChatAvailable(
                    flag: row.flag,
                    runtimeAvailable: row.runtime,
                    modelInstalled: row.installed
                ),
                row.expected,
                "flag=\(row.flag) runtime=\(row.runtime) installed=\(row.installed)"
            )
        }
    }
}
