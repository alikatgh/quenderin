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

    /** True when the tail of [text] is verbatim-looping: the last [window] CODE POINTS occur
     *  at least [threshold] times within the recent tail. Code points, not UTF-16 units — the
     *  Swift twin scans unicode scalars, so a UTF-16 scan counted every emoji/astral char twice
     *  (half the real window) and could even align mid-surrogate-pair (twin-drift audit,
     *  degeneration P2). Same unit on both platforms now. */
    fun looksDegenerate(text: String, window: Int = 160, threshold: Int = 3): Boolean {
        val cps = text.codePoints().toArray()
        if (cps.size < window * threshold) return false
        val tailSpan = window * (threshold + 2)
        val hayStart = maxOf(0, cps.size - tailSpan)
        val needleStart = cps.size - window
        // OVERLAPPING count: a loop with a period shorter than the window still matches at
        // every period offset — non-overlapping jumps undercount exactly the degenerate case.
        var count = 0
        var i = hayStart
        val end = cps.size - window
        while (i <= end) {
            var j = 0
            while (j < window && cps[i + j] == cps[needleStart + j]) j += 1
            if (j == window) {
                count += 1
                if (count >= threshold) return true
            }
            i += 1
        }
        return false
    }

    /** The twins' ONE trim set: Kotlin's `isWhitespace` (which reaches the non-breaking spaces via
     *  isSpaceChar) plus NEL U+0085 — the code point Swift's `.whitespacesAndNewlines` trims and
     *  Java doesn't; Swift unions in U+001C–U+001F from this side (twin-drift audit, degeneration P3). */
    internal fun trimEdges(s: String): String = s.trim { it.isWhitespace() || it == '\u0085' }

    /** Collapse RUNS of identical paragraphs (exact match after trimming, and only substantial
     *  ones — >= [minLength] chars) down to a single copy. Distinct paragraphs and short
     *  intentional repeats ("Yes." / "Yes.") pass through untouched. */
    fun collapseRepeatedParagraphs(text: String, minLength: Int = 40): String {
        val paragraphs = text.split("\n\n")
        if (paragraphs.size <= 1) return text
        val out = mutableListOf<String>()
        for (paragraph in paragraphs) {
            val trimmed = trimEdges(paragraph)
            val lastTrimmed = out.lastOrNull()?.let { trimEdges(it) }
            // minLength counts CODE POINTS (a UTF-16 .length saw an emoji paragraph as twice its
            // real size and collapsed what the Swift twin kept — twin-drift audit, degeneration P3).
            if (lastTrimmed != null && trimmed == lastTrimmed &&
                trimmed.codePointCount(0, trimmed.length) >= minLength
            ) {
                continue   // an exact re-run of the previous substantial paragraph
            }
            out.add(paragraph)
        }
        return out.joinToString("\n\n")
    }
}
