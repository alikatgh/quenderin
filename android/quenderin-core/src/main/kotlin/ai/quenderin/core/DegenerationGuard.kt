package ai.quenderin.core

/**
 * Last line of defense against the small-model failure that kills credibility on sight:
 * the same paragraph streamed verbatim three, four, five times. Twin of iOS
 * `DegenerationGuard` (plain code-point scans, no regex — the Swift↔Kotlin divergence
 * zone); CoreVerify pins the same cases.
 *
 * Android wiring note: the JNI engine's streaming callback can't abort mid-generation yet,
 * so Android applies [collapseRepeatedParagraphs] at settle; the mid-stream stop
 * ([looksDegenerate]) joins once the JNI abort seam lands (see docs/SHELL_ROUTER_SETTINGS.md).
 */
object DegenerationGuard {

    /** True when the tail of [text] is verbatim-looping: the last [window] characters occur
     *  at least [threshold] times within the recent tail. */
    fun looksDegenerate(text: String, window: Int = 160, threshold: Int = 3): Boolean {
        if (text.length < window * threshold) return false
        val tailSpan = window * (threshold + 2)
        val hay = text.takeLast(minOf(text.length, tailSpan))
        val needle = text.takeLast(window)
        // OVERLAPPING count: a loop with a period shorter than the window still matches at
        // every period offset — non-overlapping jumps undercount exactly the degenerate case.
        var count = 0
        var i = 0
        val end = hay.length - window
        while (i <= end) {
            if (hay.regionMatches(i, needle, 0, window)) {
                count += 1
                if (count >= threshold) return true
            }
            i += 1
        }
        return false
    }

    /** Collapse RUNS of identical paragraphs (exact match after trimming, and only substantial
     *  ones — >= [minLength] chars) down to a single copy. Distinct paragraphs and short
     *  intentional repeats ("Yes." / "Yes.") pass through untouched. */
    fun collapseRepeatedParagraphs(text: String, minLength: Int = 40): String {
        val paragraphs = text.split("\n\n")
        if (paragraphs.size <= 1) return text
        val out = mutableListOf<String>()
        for (paragraph in paragraphs) {
            val trimmed = paragraph.trim()
            val lastTrimmed = out.lastOrNull()?.trim()
            if (lastTrimmed != null && trimmed == lastTrimmed && trimmed.length >= minLength) {
                continue   // an exact re-run of the previous substantial paragraph
            }
            out.add(paragraph)
        }
        return out.joinToString("\n\n")
    }
}
