import XCTest
@testable import QuenderinKit

/// Friendly capability names are the user-facing half of every capability. The raw id (`mac.ui.tap`)
/// stays the stable identifier; these tests make sure a PERSON never has to read it as the name.
final class CapabilityDisplayNameTests: XCTestCase {

    /// Every capability a user can actually see in Settings must have a REAL entry — the prettified-id
    /// fallback is a safety net, never the shipped experience. Fails loudly if someone adds a
    /// capability without adding its friendly name to the catalog.
    func testEveryShippedCapabilityHasAnExplicitFriendlyName() {
        let missing = AgentToolkit.capabilities()
            .map(\.name)
            .filter { CapabilityCatalog.displayNames[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "capabilities missing a friendly name: \(missing)")
    }

    /// A friendly name must not read like a raw tool id — no dotted identifiers, never empty.
    func testFriendlyNamesLookHumanNotLikeIds() {
        for (id, name) in CapabilityCatalog.displayNames {
            XCTAssertFalse(name.isEmpty, "\(id) has an empty friendly name")
            XCTAssertFalse(name.contains("."), "\(id) → \"\(name)\" still looks like a raw id")
            // A real name starts with a capital and is more than a single token echo of the id.
            XCTAssertTrue(name.first?.isUppercase ?? false, "\(id) → \"\(name)\" should start capitalized")
        }
    }

    /// The specific ids the user flagged now read as plain English.
    func testTheFlaggedIdsAreNowFriendly() {
        XCTAssertEqual(CapabilityCatalog.displayName(for: "mac.ui.tap"), "Click a button")
        XCTAssertEqual(CapabilityCatalog.displayName(for: "mac.reminders.add"), "Add a reminder")
        XCTAssertEqual(CapabilityCatalog.displayName(for: "mac.mail.draft"), "Draft an email")
        XCTAssertEqual(CapabilityCatalog.displayName(for: "mac.ui.observe"), "See what’s on screen")
    }

    /// An unmapped id degrades gracefully instead of showing a dotted identifier.
    func testUnmappedIdFallsBackToAPrettifiedName() {
        XCTAssertEqual(CapabilityCatalog.displayName(for: "some.new_tool"), "Some New Tool")
    }
}
