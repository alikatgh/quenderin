import Foundation

/// The "Plan novel goals" setting — whether the agent, on a goal no curated recipe matches, asks the
/// model to author its OWN tool-name plan before it starts (docs/audits/2026-07-08-dynamic-planning.md).
///
/// Curated recipes are a small, human-vouched fast-path; they can't cover the long tail. This flag lets
/// the model plan anything — a real use of its intelligence — but a small local model plans imperfectly,
/// and a WRONG plan can mis-steer it, so the feature ships dark: OFF by default, behind this toggle, so
/// plan quality on the real on-device model is measured before any default-on decision. `AgentLoop` reads
/// it LIVE (like `AgentDeliberation`), so the change takes effect on the next run, not the next launch.
///
/// No new decision case, no new grammar, no blocklist entry: the plan decodes under the SHIPPED decision
/// grammar and is wrapped into a macOS-advisory `AgentRecipe`, so the cross-platform parity contract is
/// untouched (zero Kotlin/TS twin work).
public enum AgentDynamicPlanning {
    public static let defaultsKey = "quenderin.agentDynamicPlanning"

    /// Whether dynamic planning is enabled right now. Reads UserDefaults live (default false).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
    }
}
