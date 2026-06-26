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
        return blockedKeywords.filter { keyword ->
            // Multi-word phrases ("send money") are specific enough as substrings; single words need
            // word boundaries so "pay" doesn't fire on "repay", "pin" on "opinion", etc. (M9)
            // `(?U)` makes Java's `\b` Unicode-aware so accented text counts as word chars — without it,
            // ASCII `\b` saw 'é' as a boundary and fired "pin" on "piné", which iOS's ICU `\b`
            // (NSRegularExpression) never did. Keeps the safety gate IDENTICAL across platforms.
            if (keyword.contains(" ")) haystack.contains(keyword)
            else Regex("(?U)\\b${Regex.escape(keyword)}\\b").containsMatchIn(haystack)
        }
    }
}
