import Foundation

/// Autopilot: run a goal start-to-finish without a per-step Allow dialog.
///
/// The per-run approval is the write gate that makes the agent trustworthy — but asked on
/// EVERY mutating step it also chains the user to the keyboard, which defeats the mission
/// (local AUTONOMOUS computer use). Autopilot is the deliberate, opt-in relaxation:
///
/// - **What it skips:** the per-step Allow / Don't-allow dialog (`ApprovalBroker` answers
///   yes on the runner's behalf for the rest of the run).
/// - **What it NEVER skips:** the `SafetyBlocklist` (payments & friends refuse before any
///   approval is consulted), the standing consent tiers (a tool that isn't granted in
///   Settings still refuses), the audit ledger (every action is still recorded), and the
///   undo session (every reversible action still journals). Those are the rails; the
///   dialog is just the human-in-the-loop cadence.
///
/// OFF by default — approving each change is the right default for a new user. Mirrors the
/// `AgentDeliberation` pattern: UserDefaults-backed, read live at each run's start.
public enum AgentAutopilot {
    public static let defaultsKey = "quenderin.agentAutopilot"

    /// Whether new runs start pre-approved. Read live at `AgentSession.run` (default false).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
    }
}
