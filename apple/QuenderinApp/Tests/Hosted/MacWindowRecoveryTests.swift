#if os(macOS)
import AppKit
import XCTest
@testable import Quenderin

final class MacWindowRecoveryTests: XCTestCase {
    @MainActor
    func testDockReopenRequestsMainWhenSettingsIsStillVisible() {
        let delegate = QuenderinMacAppDelegate()
        var requests = 0
        delegate.showMainWindow = { requests += 1 }

        let useDefaultReopen = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        XCTAssertFalse(useDefaultReopen)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testDockReopenRequestsMainWhenNoWindowIsVisible() {
        let delegate = QuenderinMacAppDelegate()
        var requests = 0
        delegate.showMainWindow = { requests += 1 }

        let useDefaultReopen = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        XCTAssertFalse(useDefaultReopen)
        XCTAssertEqual(requests, 1)
    }
}
#endif
