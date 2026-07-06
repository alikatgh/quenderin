#if canImport(SwiftUI)
import XCTest
@testable import QuenderinKit

/// Q-578: the DownloadPolicy reason string tells the user to "allow cellular downloads in settings",
/// but no such setting existed. AppSettings.allowCellularDownloads is that toggle, and `downloadPolicy`
/// derives from it — the onboarding + library download gates read it. Default OFF (Wi-Fi-only, safe).
@MainActor
final class DownloadPolicySettingTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "dl-policy-\(UUID().uuidString)")!
        return d
    }

    func testDefaultsToWifiOnly() {
        let s = AppSettings(defaults: freshDefaults())
        XCTAssertFalse(s.allowCellularDownloads)
        XCTAssertEqual(s.downloadPolicy, .wifiOnly)
    }

    func testTogglingOnAllowsCellularAndPersists() {
        let defaults = freshDefaults()
        let s = AppSettings(defaults: defaults)
        s.allowCellularDownloads = true
        XCTAssertEqual(s.downloadPolicy, .wifiOrCellular)

        // Persisted: a fresh store over the same defaults reads the opt-in back.
        let reopened = AppSettings(defaults: defaults)
        XCTAssertTrue(reopened.allowCellularDownloads)
        XCTAssertEqual(reopened.downloadPolicy, .wifiOrCellular)
    }
}
#endif
