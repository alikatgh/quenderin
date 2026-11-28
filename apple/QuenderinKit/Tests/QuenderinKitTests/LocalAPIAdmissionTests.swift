import XCTest
@testable import QuenderinKit

final class LocalAPIAdmissionTests: XCTestCase {
    func testStalledHeadersCanOnlyFillPreAuthBudget() {
        var admission = LocalAPIAdmission<Int>()
        for id in 0..<8 {
            XCTAssertEqual(admission.admit(id), .admit)
            admission.promote(id)
        }
        for id in 8..<16 {
            XCTAssertEqual(admission.admit(id), .admit)
        }
        XCTAssertEqual(admission.preAuthCount, 8)
        XCTAssertEqual(admission.totalCount - admission.preAuthCount, 8)

        admission.release(0)
        XCTAssertEqual(admission.admit(16), .sendRejection)
        XCTAssertEqual(admission.preAuthCount, 8)
        XCTAssertEqual(admission.totalCount, 16)
        admission.release(16)
        XCTAssertEqual(admission.totalCount, 15)
    }

    func testLegitimateClientCanEnterWhenStalledPeerReleasesSlot() {
        var admission = LocalAPIAdmission<Int>()
        for id in 0..<8 {
            XCTAssertEqual(admission.admit(id), .admit)
        }
        XCTAssertEqual(admission.admit(8), .sendRejection)
        XCTAssertEqual(admission.admit(9), .cancel)

        admission.release(0)
        XCTAssertEqual(admission.admit(9), .admit)
        admission.promote(9)
        XCTAssertEqual(admission.preAuthCount, 7)
        XCTAssertEqual(admission.admit(10), .admit)
        XCTAssertEqual(admission.preAuthCount, 8)
        XCTAssertEqual(admission.totalCount, 10)

        admission.release(8)
        XCTAssertEqual(admission.admit(11), .sendRejection)
    }

    func testRepeatedAndLatePromotionAndReleaseDoNotChangeAccounting() {
        var admission = LocalAPIAdmission<Int>()
        XCTAssertEqual(admission.admit(1), .admit)
        XCTAssertEqual(admission.admit(1), .cancel)
        admission.promote(1)
        admission.promote(1)
        XCTAssertEqual(admission.preAuthCount, 0)
        XCTAssertEqual(admission.totalCount, 1)

        admission.release(1)
        admission.release(1)
        admission.promote(1)
        XCTAssertEqual(admission.preAuthCount, 0)
        XCTAssertEqual(admission.totalCount, 0)
        XCTAssertEqual(admission.admit(1), .admit)
        XCTAssertEqual(admission.preAuthCount, 1)
    }

    func testTotalCapStillAppliesWhenPreAuthBudgetIsEmpty() {
        var admission = LocalAPIAdmission<Int>()
        for id in 0..<16 {
            XCTAssertEqual(admission.admit(id), .admit)
            admission.promote(id)
        }
        XCTAssertEqual(admission.admit(16), .cancel)
        XCTAssertEqual(admission.preAuthCount, 0)
        XCTAssertEqual(admission.totalCount, 16)

        admission.release(0)
        XCTAssertEqual(admission.admit(16), .admit)
        XCTAssertEqual(admission.totalCount, 16)
    }
}
