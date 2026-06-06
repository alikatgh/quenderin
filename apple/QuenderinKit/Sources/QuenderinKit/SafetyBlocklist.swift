import Foundation

/// The agent's hard safety sandbox. Ported from the desktop blocklist — the
/// keywords an autonomous agent must NEVER act on without explicit human
/// confirmation (financial, destructive, or credential-touching actions).
///
/// > Never remove entries from this list. Add to it when a new dangerous action
/// > class is discovered. (Matches the project rule: "Never remove safety
/// > blocklist entries.")
public enum SafetyBlocklist {

    public static let blockedKeywords: [String] = [
        // Financial
        "pay", "payment", "purchase", "buy now", "checkout", "transfer", "send money",
        "wire", "bank", "credit card", "cvv", "venmo", "paypal",
        // Destructive
        "delete", "erase", "format", "wipe", "factory reset", "uninstall", "remove all",
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
        return blockedKeywords.filter { haystack.contains($0) }
    }
}
