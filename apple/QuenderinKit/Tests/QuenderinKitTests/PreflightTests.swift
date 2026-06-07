import XCTest
@testable import QuenderinKit

final class PreflightTests: XCTestCase {

    private func model(_ id: String) -> ModelEntry { ModelCatalog.entry(id: id)! }

    func testReadyWhenModelCompleteAmpleDisk() {
        let checklist = Preflight.checklist(
            model: model("llama32-1b-q2"),
            fileExists: true, fileSizeBytes: 400_000_000,
            availableBytes: 10_000_000_000,
            network: .wifi, policy: .wifiOnly
        )
        XCTAssertTrue(checklist.isReadyForOffline)
        XCTAssertTrue(checklist.blockers.isEmpty)
    }

    func testNotDownloadedOnCellularSurfacesWifiBlocker() {
        let checklist = Preflight.checklist(
            model: ModelCatalog.smallest,
            fileExists: false, fileSizeBytes: 0,
            availableBytes: 10_000_000_000,
            network: .cellular, policy: .wifiOnly
        )
        XCTAssertFalse(checklist.isReadyForOffline)
        XCTAssertTrue(checklist.blockers.joined().lowercased().contains("wi-fi"))
    }

    func testLowDiskSurfacesStorageBlocker() {
        let checklist = Preflight.checklist(
            model: model("llama3-8b"),
            fileExists: false, fileSizeBytes: 0,
            availableBytes: 500_000_000,           // way too little for a 4.5 GB model
            network: .wifi, policy: .wifiOnly
        )
        XCTAssertFalse(checklist.isReadyForOffline)
        XCTAssertTrue(checklist.blockers.joined().lowercased().contains("not enough"))
    }
}
