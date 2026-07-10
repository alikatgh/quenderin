import XCTest
@testable import QuenderinKit

/// Autopilot semantics on the approval broker: one grant per goal, never leaking across runs,
/// and never touching the upstream gates (blocklist / consent — pinned by WorkspaceCapabilityTests;
/// this file pins the DIALOG-cadence layer that AgentAutopilot relaxes).
final class ApprovalBrokerTests: XCTestCase {
    private let preview = ActionPreview(summary: "Move a file", mutates: true)

    /// Default cadence: request suspends, publishes `pending`, and the user's answer resolves it.
    @MainActor
    func testDefaultCadenceAsksPerAction() async {
        let broker = ApprovalBroker()
        broker.beginRun(autopilot: false)
        let answer = Task { await broker.request(self.preview) }
        // Wait for the dialog to be published (the request hops to MainActor).
        while broker.pending == nil { await Task.yield() }
        XCTAssertEqual(broker.pending?.summary, "Move a file")
        broker.resolve(false)
        let declined = await answer.value
        XCTAssertFalse(declined, "Don't-allow must reach the runner as NO")
        XCTAssertNil(broker.pending)
    }

    /// "Allow all steps for this goal": approves the pending action AND all later ones,
    /// with no further dialog published.
    @MainActor
    func testResolveAllForRunApprovesTheRestWithoutDialogs() async {
        let broker = ApprovalBroker()
        broker.beginRun(autopilot: false)
        let first = Task { await broker.request(self.preview) }
        while broker.pending == nil { await Task.yield() }
        broker.resolveAllForRun()
        let firstAnswer = await first.value
        XCTAssertTrue(firstAnswer)
        // Later steps in the SAME run: instant yes, no dialog.
        let second = await broker.request(preview)
        XCTAssertTrue(second)
        XCTAssertNil(broker.pending, "autopilot must not publish a dialog")
        XCTAssertTrue(broker.isAutoApproving)
    }

    /// The grant is scoped to the run: the next `beginRun` resets it (a goal approved
    /// wholesale yesterday must not silently pre-approve today's goal).
    @MainActor
    func testGrantNeverLeaksIntoTheNextRun() async {
        let broker = ApprovalBroker()
        broker.beginRun(autopilot: false)
        let first = Task { await broker.request(self.preview) }
        while broker.pending == nil { await Task.yield() }
        broker.resolveAllForRun()
        _ = await first.value

        broker.beginRun(autopilot: false)   // next goal
        XCTAssertFalse(broker.isAutoApproving)
        let next = Task { await broker.request(self.preview) }
        while broker.pending == nil { await Task.yield() }   // asks again — no leak
        broker.resolve(true)
        let answered = await next.value
        XCTAssertTrue(answered)
    }

    /// Settings-level autopilot: the run starts pre-approved — zero dialogs from step 1.
    @MainActor
    func testSettingsAutopilotStartsRunPreApproved() async {
        let broker = ApprovalBroker()
        broker.beginRun(autopilot: true)
        let answer = await broker.request(preview)
        XCTAssertTrue(answer)
        XCTAssertNil(broker.pending)
    }

    /// The AgentAutopilot setting itself: defaults false, round-trips, and is the value
    /// AgentSession reads live at each run's start.
    func testAutopilotSettingRoundTrip() {
        UserDefaults.standard.removeObject(forKey: AgentAutopilot.defaultsKey)
        XCTAssertFalse(AgentAutopilot.isEnabled, "must be OFF by default — approval is the safe default")
        AgentAutopilot.setEnabled(true)
        XCTAssertTrue(AgentAutopilot.isEnabled)
        AgentAutopilot.setEnabled(false)
        XCTAssertFalse(AgentAutopilot.isEnabled)
        UserDefaults.standard.removeObject(forKey: AgentAutopilot.defaultsKey)
    }
}
