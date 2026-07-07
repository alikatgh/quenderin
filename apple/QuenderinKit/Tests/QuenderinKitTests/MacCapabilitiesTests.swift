import XCTest
@testable import QuenderinKit

/// The native mac.* capability library over a fake seam — the same seam-and-fake discipline the
/// TS lab used to prove these templates (this suite mirrors its load-bearing cases). The one
/// production-only surface is `OsascriptAutomation`; everything here exercises the REAL templates,
/// parsing, escaping, tiering, and error mapping headlessly.
final class MacCapabilitiesTests: XCTestCase {

    /// Scripted mac seam: records every script; replies from a queue (or throws).
    final class FakeMac: MacAutomation, @unchecked Sendable {
        var scripts: [String] = []
        var replies: [Result<String, Error>]
        var available: Bool
        init(replies: [Result<String, Error>] = [.success("ok")], available: Bool = true) {
            self.replies = replies
            self.available = available
        }
        func runAppleScript(_ script: String) async throws -> String {
            scripts.append(script)
            let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
            return try reply.get()
        }
    }

    // MARK: escapeAppleScriptString — the injection boundary

    func testEscapeNeutralizesQuotesBackslashesAndControlRuns() {
        // Quote breakout: the classic `" & do shell script & "` smuggle stays INSIDE the literal.
        XCTAssertEqual(escapeAppleScriptString(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(escapeAppleScriptString(#"a\b"#), #"a\\b"#)
        // A RUN of control chars collapses to ONE space (twin of the TS regex `[..]+ -> ' '`).
        XCTAssertEqual(escapeAppleScriptString("line1\n\n\tline2"), "line1 line2")
        XCTAssertEqual(escapeAppleScriptString("del\u{7F}ete"), "del ete")
        XCTAssertEqual(escapeAppleScriptString("plain text"), "plain text")
    }

    func testReminderInputCannotBreakOutOfTheStringLiteral() async throws {
        let mac = FakeMac()
        let cap = ReminderAddCapability(mac: mac)
        _ = try await cap.run(#"x"} & (do shell script "rm -rf ~") & {name:"y"#)
        let script = mac.scripts[0]
        // The hostile quote arrives escaped — the template's own literal is never terminated early.
        XCTAssertTrue(script.contains(#"name:"x\"} & (do shell script \"rm -rf ~\") & {name:\"y""#))
    }

    // MARK: tiers and membership — what the spine gates on

    func testLibraryMembershipTiersAndConsent() {
        let caps = macCapabilities(mac: FakeMac())
        XCTAssertEqual(caps.map(\.name), [
            "mac.frontApp", "mac.clipboard.read", "mac.calendar.today", "mac.shortcuts.list",
            "mac.finder.reveal",
            "mac.app.open", "mac.safari.openURL", "mac.notes.create", "mac.reminders.add",
            "mac.calendar.add", "mac.mail.draft", "mac.shortcuts.run",
        ])
        for cap in caps {
            XCTAssertGreaterThan(cap.tier, .pureCompute, "\(cap.name) must not be T0")
            XCTAssertTrue(cap.requiresConsent, "\(cap.name) must require consent")
            if cap.tier == .readOnly {
                XCTAssertFalse(cap.blastRadius.mutates, "\(cap.name) is perception — must not mutate")
            } else {
                XCTAssertTrue(cap.blastRadius.mutates, "\(cap.name) writes — must declare it")
            }
        }
        XCTAssertEqual(caps.first(where: { $0.name == "mac.shortcuts.run" })?.tier, .appAction)
    }

    func testMutatingPreviewsAreTruthfulAndParseFailuresDontMutate() async throws {
        let mac = FakeMac()
        let reminder = try await ReminderAddCapability(mac: mac).plan("water the plants")
        XCTAssertTrue(reminder.mutates)
        XCTAssertTrue(reminder.summary.contains("water the plants"))
        // An unparseable input previews as a correction, NOT as a mutation (nothing to approve).
        let bad = try await CalendarAddCapability(mac: mac).plan("no pipe here")
        XCTAssertFalse(bad.mutates)
        XCTAssertTrue(bad.summary.contains("<title> | <YYYY-MM-DD HH:MM>"))
    }

    // MARK: capability behavior over the fake seam

    func testReminderAddRunsTheTemplateAndReportsBack() async throws {
        let mac = FakeMac()
        let out = try await ReminderAddCapability(mac: mac).run("  call the dentist  ")
        XCTAssertEqual(out, "Added a reminder: \"call the dentist\".")
        XCTAssertTrue(mac.scripts[0].contains("make new reminder"))
        XCTAssertTrue(mac.scripts[0].contains("call the dentist"))
    }

    func testNoteCreateFallsBackWhenICloudContainerIsMissing() async throws {
        let mac = FakeMac(replies: [
            .failure(MacAutomationError.script(message: "no iCloud account")),
            .success("ok"),
        ])
        let out = try await NoteCreateCapability(mac: mac).run("Groceries\nmilk, eggs")
        XCTAssertEqual(out, "Created a note \"Groceries\".")
        XCTAssertEqual(mac.scripts.count, 2)
        XCTAssertTrue(mac.scripts[0].contains("account \"iCloud\""))
        XCTAssertFalse(mac.scripts[1].contains("account \"iCloud\""))
    }

    func testCalendarAddBuildsOffsetDateAndRejectsRolledOverDates() async throws {
        // Fixed clock: 2026-01-01 00:00 local → an event at 2026-01-02 10:30 is a deterministic offset.
        var comps = DateComponents(); comps.year = 2026; comps.month = 1; comps.day = 1
        let cal = Calendar(identifier: .gregorian)
        let fixedNow = cal.date(from: comps)!
        let mac = FakeMac()
        let cap = CalendarAddCapability(mac: mac, now: { fixedNow })

        let out = try await cap.run("Dentist | 2026-01-02 10:30 | 45")
        XCTAssertTrue(out.contains("Added \"Dentist\""))
        let expectedOffset = (24 * 3600) + (10 * 3600) + (30 * 60)   // one day + 10:30
        XCTAssertTrue(mac.scripts[0].contains("(current date) + (\(expectedOffset))"),
                      "script should carry the exact seconds offset; got: \(mac.scripts[0])")
        XCTAssertTrue(mac.scripts[0].contains("(45 * minutes)"))

        // Feb 30 rolls over in naive date math — the components must round-trip, so it's refused.
        XCTAssertNil(cap.parse("X | 2026-02-30 10:00"))
        XCTAssertNil(cap.parse("X | 2026-13-01 10:00"))
        XCTAssertNil(cap.parse("X | 2026-01-02 24:00"))
        XCTAssertNil(cap.parse("| 2026-01-02 10:00"), "an empty title is not an event")
        // A zero/negative duration is a parse failure, not a zero-length event.
        XCTAssertNil(cap.parse("X | 2026-01-02 10:00 | 0"))
    }

    func testMailDraftRequiresAPlausibleAddressAndNeverSends() async throws {
        let mac = FakeMac()
        let cap = MailDraftCapability(mac: mac)
        XCTAssertNil(cap.parse("subject: hi | body: there"))
        XCTAssertNil(cap.parse("to: not-an-address"))
        let out = try await cap.run("to: a@b.com | subject: Hello | body: Hi there")
        XCTAssertTrue(out.contains("not sent"))
        XCTAssertTrue(mac.scripts[0].contains("outgoing message"))
        XCTAssertFalse(mac.scripts[0].contains("send msg"), "drafting must NEVER send")
    }

    func testShortcutRunPassesInputCapturesOutputAndMapsMissingShortcut() async throws {
        let mac = FakeMac(replies: [.success("42 items processed")])
        let cap = ShortcutRunCapability(mac: mac)
        let out = try await cap.run("Tidy Desktop | the downloads folder")
        XCTAssertTrue(out.contains("It returned:\n42 items processed"))
        XCTAssertTrue(mac.scripts[0].contains("run shortcut \"Tidy Desktop\" with input \"the downloads folder\""))

        let missing = FakeMac(replies: [.failure(MacAutomationError.script(message: "Can’t get shortcut \"Nope\"."))])
        let miss = try await ShortcutRunCapability(mac: missing).run("Nope")
        XCTAssertTrue(miss.contains("No shortcut named \"Nope\""))
    }

    func testOpenURLRejectsNonHttpSchemes() async throws {
        let mac = FakeMac()
        let cap = OpenURLCapability(mac: mac)
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "not a url", "https://a b.com"] {
            let out = try await cap.run(bad)
            XCTAssertTrue(out.contains("http(s) URL"), "should refuse: \(bad)")
        }
        XCTAssertTrue(mac.scripts.isEmpty, "nothing may run for a refused URL")
        _ = try await cap.run("https://quenderin.org/help")
        XCTAssertTrue(mac.scripts[0].contains("open location \"https://quenderin.org/help\""))
    }

    func testFinderRevealExpandsTildeAndRefusesControlChars() async throws {
        let mac = FakeMac()
        let cap = FinderRevealCapability(mac: mac)
        _ = try await cap.run("~/Downloads")
        XCTAssertTrue(mac.scripts[0].contains(NSHomeDirectory() + "/Downloads"))
        let refused = try await cap.run("bad\u{01}path")
        XCTAssertTrue(refused.contains("Input is a file or folder path"))
    }

    // MARK: error surface

    func testPermissionDeniedMapsToTheAutomationSettingsHint() async throws {
        let mac = FakeMac(replies: [.failure(MacAutomationError.script(message: "Not authorized to send Apple events to Reminders. (-1743)"))])
        let out = try await ReminderAddCapability(mac: mac).run("x")
        XCTAssertTrue(out.contains("Privacy & Security › Automation"))
    }

    func testTimeoutAndNotMacSurfaceHonestly() async throws {
        let timedOut = FakeMac(replies: [.failure(MacAutomationError.timeout)])
        let out = try await ClipboardReadCapability(mac: timedOut).run("")
        XCTAssertTrue(out.contains("Timed out"))

        let notMac = FakeMac(available: false)
        let refused = try await FrontAppCapability(mac: notMac).run("")
        XCTAssertEqual(refused, "This runs on macOS only.")
        XCTAssertTrue(notMac.scripts.isEmpty)
    }

    // MARK: the spine gates the library with zero new plumbing

    func testGateBlocksABlocklistedInputAndConsentGatesTheRest() async throws {
        let mac = FakeMac()
        let reminder = ReminderAddCapability(mac: mac)
        // Blocklist first: a blocklisted word in the input refuses outright.
        let blocked = try await CapabilityGate.assess(reminder, input: "pay the rent", isConsented: true)
        guard case .blocked = blocked else { return XCTFail("expected .blocked, got \(blocked)") }
        // No consent → needsConsent with the truthful preview.
        let needs = try await CapabilityGate.assess(reminder, input: "water the plants", isConsented: false)
        guard case .needsConsent(let preview) = needs else { return XCTFail("expected .needsConsent, got \(needs)") }
        XCTAssertTrue(preview.mutates)
        // Consented → allowed; nothing ran through the seam during ANY of this (plan is pure).
        let allowed = try await CapabilityGate.assess(reminder, input: "water the plants", isConsented: true)
        guard case .allowed = allowed else { return XCTFail("expected .allowed, got \(allowed)") }
        XCTAssertTrue(mac.scripts.isEmpty, "assess must never execute the capability")
    }

    func testMacCapabilitiesAreRegisteredInTheToolkitOnMacOS() {
        #if os(macOS)
        let names = AgentToolkit.capabilities().map(\.name)
        XCTAssertTrue(names.contains("mac.reminders.add"))
        XCTAssertTrue(names.contains("mac.shortcuts.run"))
        #endif
    }
}
