package ai.quenderin.core

/**
 * The agent's hard safety sandbox. Ported from the desktop/Swift blocklist — the
 * keywords an autonomous agent must NEVER act on without explicit confirmation.
 * Never remove entries.
 */
object SafetyBlocklist {
    val blockedKeywords: List<String> = listOf(
        // Financial
        "pay", "payment", "purchase", "buy now", "checkout", "transfer", "send money",
        "wire", "bank", "credit card", "cvv", "venmo", "paypal",
        // Destructive
        "delete", "erase", "format", "wipe", "factory reset", "uninstall", "remove all",
        // Credentials / sensitive
        "password", "passcode", "pin", "ssn", "social security", "private key", "seed phrase",
    )

    fun isBlocked(text: String): Boolean = matches(text).isNotEmpty()

    /** The specific blocked keywords found — so the UI can explain *why*. */
    fun matches(text: String): List<String> {
        val haystack = text.lowercase()
        return blockedKeywords.filter { haystack.contains(it) }
    }
}
