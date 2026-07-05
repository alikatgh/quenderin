import Foundation

/// The agent's hard safety sandbox. Ported from the desktop blocklist — the
/// keywords an autonomous agent must NEVER act on without explicit human
/// confirmation (financial, destructive, or credential-touching actions).
///
/// > Never remove entries from this list. Add to it when a new dangerous action
/// > class is discovered. (Matches the project rule: "Never remove safety
/// > blocklist entries.")
public enum SafetyBlocklist {

    // Twin of shared/safety-blocklist.json — scripts/check_safety_parity.py enforces exact
    // set equality with the canonical list and the Kotlin/TS twins in CI (the three lists had
    // silently drifted; audit Q-014 / AGENT_AUTONOMY_PLAN Milestone 0).
    public static let blockedKeywords: [String] = [
        // Financial
        "pay", "payment", "purchase", "buy", "buy now", "checkout", "transfer", "send money",
        "wire", "bank", "credit card", "cvv", "venmo", "paypal",
        "confirm purchase", "confirm payment", "place order", "withdraw",
        // Destructive
        "delete", "erase", "format", "wipe", "factory reset", "uninstall", "remove all",
        "revoke", "deactivate",
        // Credentials / sensitive
        "password", "passcode", "pin", "ssn", "social security", "private key", "seed phrase",
    ]

    /// True if `text` touches any blocked action.
    public static func isBlocked(_ text: String) -> Bool {
        !matches(in: text).isEmpty
    }

    /// The specific blocked keywords found in `text` — so the UI can explain
    /// *why* an action was withheld, not just that it was.
    public static func matches(in text: String) -> [String] {
        let haystack = text.lowercased()
        return blockedKeywords.filter { keyword in
            // Multi-word phrases ("send money") are specific enough as substrings; single words need
            // word boundaries so "pay" doesn't fire on "repay", "pin" on "opinion", etc. (M9)
            if keyword.contains(" ") { return haystack.contains(keyword) }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            return haystack.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
