import Foundation

/// Last line of defense against the small-model failure that kills credibility on sight:
/// the same paragraph streamed verbatim three, four, five times. The sampler's repetition
/// penalty prevents most of it at the source; this guard catches what slips through —
/// detect the loop mid-stream (stop paying for degenerate tokens) and collapse exact
/// duplicate paragraphs before the reply settles.
///
/// Pure string scans, no regex — hand-ported twin of Kotlin `DegenerationGuard`
/// (CoreVerify pins the same cases).
public enum DegenerationGuard {

    /// True when the tail of `text` is verbatim-looping: the last `window` characters
    /// occur at least `threshold` times within the recent tail. Cheap enough to run
    /// every few dozen tokens during streaming.
    public static func looksDegenerate(_ text: String, window: Int = 160, threshold: Int = 3) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let tailSpan = window * (threshold + 2)
        guard scalars.count >= window * threshold else { return false }
        let needle = scalars.suffix(window)
        let hay = scalars.suffix(min(scalars.count, tailSpan))
        // OVERLAPPING count: a loop with a period shorter than the window still matches at
        // every period offset — non-overlapping jumps undercount exactly the degenerate case.
        var count = 0
        var i = hay.startIndex
        let end = hay.endIndex - window
        while i <= end {
            if hay[i] == needle.first, Array(hay[i..<i + window]) == Array(needle) {
                count += 1
                if count >= threshold { return true }
            }
            i += 1
        }
        return false
    }

    /// The twins' ONE trim set: `.whitespacesAndNewlines` (which includes NEL U+0085 and the
    /// non-breaking spaces) plus U+001C–U+001F — the separators Java's `isWhitespace` trims and
    /// this side didn't (twin-drift audit, degeneration P3). Kotlin unions in NEL from its side.
    static let trimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))

    static func trimEdges(_ s: String) -> String {
        s.trimmingCharacters(in: trimSet)
    }

    /// Collapse RUNS of identical paragraphs (exact match after trimming, and only
    /// substantial ones — ≥ `minLength` characters) down to a single copy. Distinct
    /// paragraphs and short intentional repeats ("Yes." / "Yes.") pass through untouched.
    public static func collapseRepeatedParagraphs(_ text: String, minLength: Int = 40) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        guard paragraphs.count > 1 else { return text }
        var out: [String] = []
        for paragraph in paragraphs {
            let trimmed = trimEdges(paragraph)
            // minLength counts CODE POINTS (unicode scalars) — grapheme `.count` saw a ZWJ family
            // emoji as 1 where the Kotlin twin saw 7+, so the "substantial enough to collapse"
            // gate fired at different real lengths (twin-drift audit, degeneration P3).
            if let last = out.last,
               trimmed == trimEdges(last),
               trimmed.unicodeScalars.count >= minLength {
                continue   // an exact re-run of the previous substantial paragraph
            }
            out.append(paragraph)
        }
        return out.joined(separator: "\n\n")
    }
}
