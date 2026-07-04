import XCTest
@testable import QuenderinKit

/// The consent gate must ask exactly once per install — and must ask users who predate the
/// screen even though they were already welcomed (separate flag from WelcomeGate).
final class ConsentGateTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ConsentGateTests")!
        defaults.removePersistentDomain(forName: "ConsentGateTests")
    }

    func testFreshInstallNeedsConsent() {
        XCTAssertTrue(ConsentGate.needsConsent(defaults: defaults))
    }

    func testAcceptingIsRemembered() {
        ConsentGate.markAccepted(defaults: defaults)
        XCTAssertFalse(ConsentGate.needsConsent(defaults: defaults))
    }

    func testWelcomedUserStillNeedsConsent() {
        WelcomeGate.markWelcomed(defaults: defaults)
        XCTAssertTrue(ConsentGate.needsConsent(defaults: defaults),
                      "Existing users who predate the consent screen must still accept it once")
    }
}
