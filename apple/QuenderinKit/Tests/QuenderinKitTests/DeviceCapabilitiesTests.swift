import XCTest
@testable import QuenderinKit

/// The T1 device-perception capabilities over fake seams (the pasteboard, calendar, and status
/// readers are the only production surfaces). Read-only by declaration — the spine's gate treats
/// them as consent-gated perception, never approval-gated writes.
final class DeviceCapabilitiesTests: XCTestCase {

    struct FakePasteboard: PasteboardReader {
        let text: String?
        func readText() -> String? { text }
    }

    struct FakeCalendar: CalendarReader {
        let events: [(title: String, time: String)]?
        func todaysEvents() async -> [(title: String, time: String)]? { events }
    }

    struct FakeStatus: DeviceStatusReader {
        let battery: Double?
        let free: Int64?
        func batteryLevel() -> Double? { battery }
        func freeDiskBytes() -> Int64? { free }
    }

    func testTiersAndBlastRadiiAreReadOnlyPerception() {
        let caps: [any Capability] = [
            DeviceClipboardReadCapability(pasteboard: FakePasteboard(text: nil)),
            CalendarTodayDeviceCapability(reader: FakeCalendar(events: nil)),
            DeviceStatusCapability(status: FakeStatus(battery: nil, free: nil)),
        ]
        for cap in caps {
            XCTAssertEqual(cap.tier, .readOnly, "\(cap.name) is perception")
            XCTAssertFalse(cap.blastRadius.mutates, "\(cap.name) must not mutate")
            XCTAssertTrue(cap.requiresConsent, "\(cap.name) still needs the user's grant")
        }
    }

    func testClipboardReadsTruncatesAndHandlesEmpty() async throws {
        let filled = DeviceClipboardReadCapability(pasteboard: FakePasteboard(text: "copied text"))
        let out = try await filled.run("")
        XCTAssertEqual(out, "copied text")

        let long = DeviceClipboardReadCapability(pasteboard: FakePasteboard(text: String(repeating: "x", count: 5000)))
        let truncated = try await long.run("")
        XCTAssertTrue(truncated.hasSuffix("[…clipboard truncated]"))

        let empty = DeviceClipboardReadCapability(pasteboard: FakePasteboard(text: nil))
        let none = try await empty.run("")
        XCTAssertEqual(none, "The clipboard is empty (or holds no text).")
    }

    func testCalendarRendersEventsDeniedAndEmptyHonestly() async throws {
        let events = CalendarTodayDeviceCapability(reader: FakeCalendar(events: [
            (title: "Standup", time: "9:30"), (title: "Dentist", time: "14:00"),
        ]))
        let out = try await events.run("")
        XCTAssertEqual(out, "Standup @ 9:30\nDentist @ 14:00")

        let denied = CalendarTodayDeviceCapability(reader: FakeCalendar(events: nil))
        let refusal = try await denied.run("")
        XCTAssertTrue(refusal.contains("wasn't granted"))

        let free = CalendarTodayDeviceCapability(reader: FakeCalendar(events: []))
        let nothing = try await free.run("")
        XCTAssertEqual(nothing, "No events on your calendar today.")
    }

    func testStatusFormatsAvailableSensesAndSaysSoWhenNoneAre() async throws {
        let both = DeviceStatusCapability(status: FakeStatus(battery: 0.87, free: 12_300_000_000))
        let out = try await both.run("")
        XCTAssertEqual(out, "Battery: 87% · Free storage: 12.3 GB")

        let none = DeviceStatusCapability(status: FakeStatus(battery: nil, free: nil))
        let honest = try await none.run("")
        XCTAssertEqual(honest, "Couldn't read the device status here.")
    }

    func testGateGivesPerceptionNoApprovalPathButKeepsConsent() async throws {
        let cap = DeviceClipboardReadCapability(pasteboard: FakePasteboard(text: "secret"))
        // No consent → needsConsent (never silently reads).
        let ungranted = try await CapabilityGate.assess(cap, input: "", isConsented: false)
        guard case .needsConsent = ungranted else { return XCTFail("expected needsConsent") }
        // Consented → allowed with a non-mutating preview (no per-run approval needed).
        let granted = try await CapabilityGate.assess(cap, input: "", isConsented: true)
        guard case .allowed(let preview) = granted else { return XCTFail("expected allowed") }
        XCTAssertFalse(preview.mutates)
    }
}
