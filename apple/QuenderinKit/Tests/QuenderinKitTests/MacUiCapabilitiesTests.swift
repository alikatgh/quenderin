import XCTest
@testable import QuenderinKit

/// The mac.ui.* GUI-driving capabilities — click/type/menu/key into ANY app via the accessibility
/// tree. Like the mac.* AppleScript tests, everything here drives the REAL capability logic
/// (resolve-by-label, blocklist re-check, formatting) through a fake seam; the one production-only
/// surface is `OsascriptMacUi`. Twin coverage of the TS `macUiCapabilities` suite.
final class MacUiCapabilitiesTests: XCTestCase {

    /// A fake accessibility seam: canned elements + recorded actions, with optional injected errors.
    final class FakeMacUi: MacUi, @unchecked Sendable {
        let available: Bool
        var elements: [MacUiElement]
        var observeError: Error?
        var actionError: Error?
        private(set) var clicks: [String] = []
        private(set) var typed: [String] = []
        private(set) var keys: [String] = []
        private(set) var menus: [[String]] = []

        init(available: Bool = true, elements: [MacUiElement] = [], observeError: Error? = nil, actionError: Error? = nil) {
            self.available = available
            self.elements = elements
            self.observeError = observeError
            self.actionError = actionError
        }
        func observe() async throws -> [MacUiElement] { if let e = observeError { throw e }; return elements }
        func click(_ label: String) async throws { if let e = actionError { throw e }; clicks.append(label) }
        func typeText(_ text: String) async throws { if let e = actionError { throw e }; typed.append(text) }
        func pressKey(_ key: String) async throws { if let e = actionError { throw e }; keys.append(key) }
        func clickMenu(_ path: [String]) async throws { if let e = actionError { throw e }; menus.append(path) }
    }

    private func els(_ pairs: [(String, String)]) -> [MacUiElement] {
        pairs.map { MacUiElement(label: $0.0, role: $0.1) }
    }

    // MARK: observe (T1 perception)

    func testObserveFormatsElementsAndCapsAtSixty() async throws {
        let many = (1...75).map { MacUiElement(label: "Item \($0)", role: "button") }
        let ui = FakeMacUi(elements: many)
        let out = try await MacUiObserveCapability(ui: ui).run("")
        XCTAssertTrue(out.contains("- [button] Item 1"))
        XCTAssertTrue(out.contains("- [button] Item 60"))
        XCTAssertFalse(out.contains("Item 61"), "must cap the list at 60")
        XCTAssertTrue(out.contains("[…15 more]"), "must disclose how many were withheld")
    }

    func testObserveReportsAnEmptyScreenHonestly() async throws {
        let out = try await MacUiObserveCapability(ui: FakeMacUi(elements: [])).run("")
        XCTAssertTrue(out.contains("No named elements"))
    }

    // MARK: tap (T3 — resolve by visible label, never a pixel)

    func testTapResolvesExactThenPartialLabelAndClicks() async throws {
        let ui = FakeMacUi(elements: els([("Send", "button"), ("Send Later", "button"), ("Cancel", "button")]))
        // Exact "Send" wins even though "Send Later" also contains it.
        let out = try await MacUiTapCapability(ui: ui).run("send")
        XCTAssertEqual(out, "Clicked \"Send\".")
        XCTAssertEqual(ui.clicks, ["Send"])
        // A unique partial match resolves too.
        _ = try await MacUiTapCapability(ui: ui).run("cance")
        XCTAssertEqual(ui.clicks, ["Send", "Cancel"])
    }

    func testTapRefusesAmbiguousAndMissingLabelsWithoutClicking() async throws {
        let ui = FakeMacUi(elements: els([("Save", "button"), ("Save As", "menu item")]))
        // "sav" is a partial that hits both (no exact winner) → ambiguous. (An exact "save" would
        // uniquely resolve to the "Save" button and click it — tested above.)
        let ambiguous = try await MacUiTapCapability(ui: ui).run("sav")
        XCTAssertTrue(ambiguous.contains("matches 2 elements"))
        let missing = try await MacUiTapCapability(ui: ui).run("Publish")
        XCTAssertTrue(missing.contains("No element labeled"))
        XCTAssertTrue(ui.clicks.isEmpty, "neither an ambiguous nor a missing label may click anything")
    }

    func testTapReChecksTheResolvedLabelAgainstTheBlocklist() async throws {
        // Defense in depth: the input "confirm" passes, but the RESOLVED element is destructive.
        let ui = FakeMacUi(elements: els([("Delete Everything", "button")]))
        let out = try await MacUiTapCapability(ui: ui).run("Delete Everything")
        XCTAssertTrue(out.contains("Refused"), "a blocked resolved element must be refused")
        XCTAssertTrue(ui.clicks.isEmpty, "a refused element must never be clicked")
    }

    func testTapPlanPreviewsWithoutClicking() async throws {
        let ui = FakeMacUi(elements: els([("Send", "button")]))
        let preview = try await MacUiTapCapability(ui: ui).plan("Send")
        XCTAssertTrue(preview.mutates)
        XCTAssertTrue(preview.summary.contains("Click \"Send\""))
        XCTAssertTrue(ui.clicks.isEmpty, "plan must be side-effect-free")
    }

    // MARK: tap verify() — the agent checks its own click landed

    func testTapVerifyFlagsAnUnchangedScreen() async throws {
        let ui = FakeMacUi(elements: els([("Send", "button")]))
        let cap = MacUiTapCapability(ui: ui)
        _ = try await cap.run("Send")                 // captures the pre-tap signature of [Send]
        let v = await cap.verify("Send")              // screen still [Send] → nothing happened
        XCTAssertFalse(v.ok)
        XCTAssertTrue(v.detail.contains("did not change"))
    }

    func testTapVerifyPassesWhenTheScreenChanged() async throws {
        let ui = FakeMacUi(elements: els([("Send", "button")]))
        let cap = MacUiTapCapability(ui: ui)
        _ = try await cap.run("Send")
        ui.elements = els([("Message sent", "static text")])   // the click visibly changed the screen
        let v = await cap.verify("Send")
        XCTAssertTrue(v.ok)
        XCTAssertTrue(v.detail.contains("changed"))
    }

    func testRunnerSurfacesAnUnverifiedTapToTheAgent() async throws {
        // The spine wiring: a tap whose screen doesn't change comes back to the agent WITH the
        // honest "couldn't confirm" note appended — the click still counts as run, just flagged.
        let ui = FakeMacUi(elements: els([("Send", "button")]))
        let consent = InMemoryConsentStore()
        consent.setGranted("mac.ui.tap", true)
        let runner = CapabilityRunner(consent: consent, approve: { _ in true })
        let out = await runner.execute(MacUiTapCapability(ui: ui), input: "Send")
        XCTAssertTrue(out.contains("Clicked \"Send\""), "the click itself still succeeds")
        XCTAssertTrue(out.contains("Couldn't confirm it worked"),
                      "an unchanged screen after a tap must be surfaced, not hidden as success")
        XCTAssertEqual(ui.clicks, ["Send"])
    }

    func testRunnerLeavesAVerifiedTapUnannotated() async throws {
        // The happy path: when the CLICK changes the screen, no scary note is appended. The fake
        // mutates its elements inside click() (as a real UI would), so observe-before ≠ observe-after.
        final class ClickChangesScreenUi: MacUi, @unchecked Sendable {
            let available = true
            var elements: [MacUiElement] = [MacUiElement(label: "Send", role: "button")]
            private(set) var clicks: [String] = []
            func observe() async throws -> [MacUiElement] { elements }
            func click(_ label: String) async throws {
                clicks.append(label)
                elements = [MacUiElement(label: "Message sent", role: "static text")]
            }
            func typeText(_ text: String) async throws {}
            func pressKey(_ key: String) async throws {}
            func clickMenu(_ path: [String]) async throws {}
        }
        let consent = InMemoryConsentStore()
        consent.setGranted("mac.ui.tap", true)
        let runner = CapabilityRunner(consent: consent, approve: { _ in true })
        let out = await runner.execute(MacUiTapCapability(ui: ClickChangesScreenUi()), input: "Send")
        XCTAssertTrue(out.contains("Clicked \"Send\""))
        XCTAssertFalse(out.contains("Couldn't confirm"), "a screen that changed must NOT be flagged")
    }

    // MARK: type

    func testTypeSendsFullTextButTruncatesTheDisplay() async throws {
        let ui = FakeMacUi()
        let long = String(repeating: "x", count: 200)
        let out = try await MacUiTypeCapability(ui: ui).run(long)
        XCTAssertEqual(ui.typed, [long], "the full text must be sent to the field")
        XCTAssertTrue(out.contains("…"), "the confirmation must truncate the echo")
        let empty = try await MacUiTypeCapability(ui: ui).run("   ")
        XCTAssertEqual(empty, "Nothing to type.")
        XCTAssertEqual(ui.typed.count, 1, "an empty type must not reach the seam")
    }

    // MARK: menu (nested paths + blocklist re-check)

    func testMenuParsesNestedPathAndClicksIt() async throws {
        let ui = FakeMacUi()
        // A clean 3-level path. (Note: a "Format > …" path is deliberately REFUSED because "format"
        // is a blocklist keyword — the common-menu false-positive is faithful to the TS twin and
        // exercised in the blocklist test below, not here.)
        let out = try await MacUiMenuCapability(ui: ui).run("Insert > Table > Rows")
        XCTAssertEqual(ui.menus, [["Insert", "Table", "Rows"]])
        XCTAssertTrue(out.contains("Insert > Table > Rows"))
    }

    func testMenuRejectsMalformedInputAndBlocklistedItems() async throws {
        let ui = FakeMacUi()
        let bad = try await MacUiMenuCapability(ui: ui).run("JustOneSegment")
        XCTAssertTrue(bad.contains("<Menu> > <Item>"))
        let blocked = try await MacUiMenuCapability(ui: ui).run("File > Delete Backups")
        XCTAssertTrue(blocked.contains("Refused"))
        XCTAssertTrue(ui.menus.isEmpty, "neither malformed nor blocked menu paths may reach the seam")
    }

    // MARK: key (navigation whitelist)

    func testKeyAcceptsNavigationKeysAndRejectsCharacters() async throws {
        let ui = FakeMacUi()
        _ = try await MacUiKeyCapability(ui: ui).run("Return")   // case-insensitive
        _ = try await MacUiKeyCapability(ui: ui).run("escape")
        XCTAssertEqual(ui.keys, ["return", "escape"])
        let rejected = try await MacUiKeyCapability(ui: ui).run("a")
        XCTAssertTrue(rejected.contains("navigation key"))
        XCTAssertEqual(ui.keys.count, 2, "a non-whitelisted key must never reach the seam")
    }

    // MARK: honesty on the two real-world failure modes

    func testAccessibilityPermissionErrorMapsToTheAccessibilitySettingsHint() async throws {
        let denied = FakeMacUi(observeError: MacAutomationError.script(message: "System Events got an error: osascript is not allowed assistive access. (-1719)"))
        let out = try await MacUiObserveCapability(ui: denied).run("")
        XCTAssertTrue(out.contains("Privacy & Security › Accessibility"),
                      "an AX-permission block must point the user at Accessibility, not dead-end")
    }

    func testNotMacRefusesEverythingWithoutTouchingTheSeam() async throws {
        let ui = FakeMacUi(available: false, elements: els([("Send", "button")]))
        let noMac = "This runs on macOS only."
        let observe = try await MacUiObserveCapability(ui: ui).run("")
        let tap = try await MacUiTapCapability(ui: ui).run("Send")
        let type = try await MacUiTypeCapability(ui: ui).run("hi")
        let key = try await MacUiKeyCapability(ui: ui).run("return")
        let menu = try await MacUiMenuCapability(ui: ui).run("File > Save")
        XCTAssertEqual([observe, tap, type, key, menu], Array(repeating: noMac, count: 5))
        XCTAssertTrue(ui.clicks.isEmpty && ui.typed.isEmpty && ui.keys.isEmpty && ui.menus.isEmpty)
    }

    // MARK: the toolkit factory registers all five, correctly tiered

    func testFactoryShipsAllFiveAtTheRightTiers() {
        let caps = macUiCapabilities(ui: FakeMacUi())
        XCTAssertEqual(caps.map(\.name), ["mac.ui.observe", "mac.ui.tap", "mac.ui.type", "mac.ui.key", "mac.ui.menu"])
        XCTAssertEqual(caps.first { $0.name == "mac.ui.observe" }?.tier, .readOnly)
        for action in ["mac.ui.tap", "mac.ui.type", "mac.ui.key", "mac.ui.menu"] {
            XCTAssertEqual(caps.first { $0.name == action }?.tier, .appAction, "\(action) must be T3 (per-run approval)")
        }
    }
}
