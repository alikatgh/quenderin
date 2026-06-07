import XCTest
@testable import QuenderinKit

final class DownloadPolicyTests: XCTestCase {

    func testWifiOnlyBlocksCellularWithReason() {
        XCTAssertFalse(DownloadPolicy.wifiOnly.allows(.cellular))
        XCTAssertNotNil(DownloadPolicy.wifiOnly.reason(for: .cellular))
    }

    func testWifiOnlyAllowsWifi() {
        XCTAssertTrue(DownloadPolicy.wifiOnly.allows(.wifi))
        XCTAssertNil(DownloadPolicy.wifiOnly.reason(for: .wifi))
    }

    func testNoConnectionAlwaysBlocked() {
        XCTAssertFalse(DownloadPolicy.wifiOnly.allows(.none))
        XCTAssertFalse(DownloadPolicy.wifiOrCellular.allows(.none))
        XCTAssertNotNil(DownloadPolicy.wifiOrCellular.reason(for: .none))
    }

    func testCellularAllowedWhenPermitted() {
        XCTAssertTrue(DownloadPolicy.wifiOrCellular.allows(.cellular))
        XCTAssertNil(DownloadPolicy.wifiOrCellular.reason(for: .cellular))
    }
}
