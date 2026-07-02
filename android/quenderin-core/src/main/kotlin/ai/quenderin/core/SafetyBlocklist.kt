package ai.quenderin.core

import java.util.regex.Pattern

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

    // Precompiled word-boundary matchers for the single-word keywords. Unicode-aware boundaries are
    // built from lookarounds over the Unicode letter/number/underscore classes ([\p{L}\p{N}_]) instead
    // of a Unicode-aware `\b`. This matters because Android's regex engine (ICU-backed) supports NEITHER
    // the inline `(?U)` flag NOR the `UNICODE_CHARACTER_CLASS` compile flag: the original `(?U)\b…\b`
    // compiled on the desktop JVM (where the unit tests run and passed) but THREW on Android, so the app
    // CRASHED the instant any assistant message rendered (MessageBubble → isFlagged → isBlocked) — the
    // real cause of "chat never answers" on-device. `\p{L}`/`\p{N}` + lookaround ARE supported on
    // Android, so this keeps the iOS-ICU parity (accented text adjacent to a keyword counts as a word
    // char, so "pin" does not fire on "piné") without the crashing flags. (M9 + the Android regex crash)
    private val wordPatterns: Map<String, Pattern> = blockedKeywords
        .filter { !it.contains(" ") }
        .associateWith { Pattern.compile("(?<![\\p{L}\\p{N}_])" + Pattern.quote(it) + "(?![\\p{L}\\p{N}_])") }

    fun isBlocked(text: String): Boolean = matches(text).isNotEmpty()

    /** The specific blocked keywords found — so the UI can explain *why*. */
    fun matches(text: String): List<String> {
        val haystack = text.lowercase()
        return blockedKeywords.filter { keyword ->
            // Multi-word phrases ("send money") are specific enough as substrings; single words need
            // word boundaries so "pay" doesn't fire on "repay", "pin" on "opinion", etc. (M9)
            if (keyword.contains(" ")) haystack.contains(keyword)
            else wordPatterns.getValue(keyword).matcher(haystack).find()
        }
    }
}
