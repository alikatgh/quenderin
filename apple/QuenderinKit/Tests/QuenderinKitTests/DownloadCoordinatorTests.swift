import XCTest
@testable import QuenderinKit

/// Pins Q-003: the single in-flight-download guard that keeps two writers off the same target file.
final class DownloadCoordinatorTests: XCTestCase {

    func testFirstClaimSucceedsSecondConcurrentClaimFails() async {
        let coord = DownloadCoordinator()
        let name = "model-\(UUID().uuidString).gguf"

        let first = await coord.claim(name)
        let second = await coord.claim(name)   // same file, still in flight

        XCTAssertTrue(first, "the first writer may proceed")
        XCTAssertFalse(second, "a second concurrent writer to the SAME file must be refused (Q-003)")
    }

    func testReleaseAllowsAReclaim() async {
        let coord = DownloadCoordinator()
        let name = "model-\(UUID().uuidString).gguf"

        let firstClaim = await coord.claim(name)
        await coord.release(name)
        let stillClaimed = await coord.isClaimed(name)
        let reclaim = await coord.claim(name)

        XCTAssertTrue(firstClaim)
        XCTAssertFalse(stillClaimed)
        XCTAssertTrue(reclaim, "after release the file can be claimed again")
    }

    func testDifferentFilesDoNotBlockEachOther() async {
        let coord = DownloadCoordinator()
        let a = await coord.claim("a.gguf")
        let b = await coord.claim("b.gguf")
        XCTAssertTrue(a)
        XCTAssertTrue(b, "distinct target files never contend")
    }

    func testReleaseIsIdempotent() async {
        let coord = DownloadCoordinator()
        let name = "model-\(UUID().uuidString).gguf"
        await coord.release(name)          // release something never claimed
        let claim = await coord.claim(name)
        await coord.release(name)
        await coord.release(name)          // double release must not throw or wedge state
        let claimedNow = await coord.isClaimed(name)
        XCTAssertTrue(claim)
        XCTAssertFalse(claimedNow)
    }
}
