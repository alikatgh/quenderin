import Foundation

/// The "Deeper reasoning" setting — whether the agent runs a `<think>` pass before each decision.
///
/// Qwen3 is a reasoning-tuned model, but the decision grammar forces it to emit JSON from the first
/// token, so it commits to a tool with zero deliberation (Qwen3 runtime audit, issue #1). Turning
/// this on lets it reason first, which improves tool selection — at the cost of speed (hundreds of
/// extra on-device tokens per step). Because that's a real trade the user should own, it's OFF by
/// default and lives behind a Settings toggle; `AgentLoop` reads it LIVE so the change takes effect
/// on the next step, not the next launch.
public enum AgentDeliberation {
    public static let defaultsKey = "quenderin.agentDeliberation"

    /// Whether the deliberation pass is enabled right now. Reads UserDefaults live (default false).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: defaultsKey)
    }
}
