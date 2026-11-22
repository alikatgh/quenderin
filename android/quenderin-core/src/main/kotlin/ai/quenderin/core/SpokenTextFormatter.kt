package ai.quenderin.core

import java.util.Locale

data class SpeechVocabularyTerm(
    val term: String,
    val phoneticHints: List<String> = emptyList(),
    val caseSensitive: Boolean = false,
)

data class SpeechFormattingOptions(
    val vocabulary: List<SpeechVocabularyTerm> = emptyList(),
    val removeFillerWords: Boolean = false,
    val spokenPunctuation: Boolean = false,
    val spokenLists: Boolean = false,
    val frenchSpacing: Boolean = false,
    val endWithPeriod: Boolean = false,
    val lowercaseOutput: Boolean = false,
    val language: String? = null,
)

/**
 * Pure Kotlin dictation formatting pipeline (MIT port of anomalyco/hex HEXShared).
 */
object SpokenTextFormatter {
    private data class Rule(val needle: String, val replacement: String, val caseSensitive: Boolean)
    private data class Span(val start: Int, val end: Int, val replacement: String)

    private val punctuationRules = listOf(
        Regex("\\bnew paragraph\\b", RegexOption.IGNORE_CASE) to "\n\n",
        Regex("\\bnew line\\b", RegexOption.IGNORE_CASE) to "\n",
        Regex("\\bquestion mark\\b", RegexOption.IGNORE_CASE) to "?",
        Regex("\\bexclamation point\\b", RegexOption.IGNORE_CASE) to "!",
        Regex("\\bexclamation mark\\b", RegexOption.IGNORE_CASE) to "!",
        Regex("\\bsemicolon\\b", RegexOption.IGNORE_CASE) to ";",
        Regex("\\bcolon\\b", RegexOption.IGNORE_CASE) to ":",
        Regex("\\bcomma\\b", RegexOption.IGNORE_CASE) to ",",
        Regex("\\bperiod\\b", RegexOption.IGNORE_CASE) to ".",
    )

    fun applyVocabularySpelling(text: String, vocabulary: List<SpeechVocabularyTerm>): String {
        if (text.isEmpty() || vocabulary.isEmpty()) return text
        val rules = mutableListOf<Rule>()
        val seen = HashSet<String>()
        for (entry in vocabulary.take(100)) {
            val term = entry.term.trim()
            if (term.isEmpty()) continue
            for (raw in listOf(term) + entry.phoneticHints) {
                val candidate = raw.trim()
                if (candidate.isEmpty()) continue
                val key = "${if (entry.caseSensitive) "s" else "i"}:${candidate.lowercase(Locale.ROOT)}->$term"
                if (seen.add(key)) {
                    rules.add(Rule(candidate, term, entry.caseSensitive))
                }
            }
        }
        if (rules.isEmpty()) return text
        rules.sortByDescending { it.needle.length }

        val spans = mutableListOf<Span>()
        for (rule in rules) {
            val escaped = Regex.escape(rule.needle)
            val pattern = "(?<![\\p{L}\\p{N}_])$escaped(?![\\p{L}\\p{N}_])"
            val options = if (rule.caseSensitive) emptySet() else setOf(RegexOption.IGNORE_CASE)
            val regex = Regex(pattern, options)
            for (match in regex.findAll(text)) {
                val start = match.range.first
                val end = match.range.last + 1
                if (spans.none { start < it.end && end > it.start }) {
                    spans.add(Span(start, end, rule.replacement))
                }
            }
        }
        if (spans.isEmpty()) return text
        spans.sortBy { it.start }

        val out = StringBuilder(text.length)
        var cursor = 0
        for (span in spans) {
            out.append(text, cursor, span.start)
            out.append(span.replacement)
            cursor = span.end
        }
        out.append(text, cursor, text.length)
        return out.toString()
    }

    fun applySpokenPunctuation(text: String): String {
        if (text.isEmpty()) return text
        var out = text
        for ((pattern, symbol) in punctuationRules) {
            out = pattern.replace(out, Regex.escapeReplacement(symbol))
        }
        return Regex("[ \\t]+([.,!?;:])").replace(out, "$1")
    }

    fun applySpokenLists(text: String): String {
        if (text.isEmpty()) return text
        val ordinals = listOf("first", "second", "third", "fourth", "fifth")
        var working = text
        var hits = 0
        for ((index, word) in ordinals.withIndex()) {
            val pattern = Regex("(?i)(?:^|\\s)$word[:,]?\\s+")
            if (pattern.containsMatchIn(working)) {
                hits++
                val prefix = if (index == 0) "1. " else "\n${index + 1}. "
                working = pattern.replaceFirst(working, Regex.escapeReplacement(prefix))
            } else {
                break
            }
        }
        return if (hits >= 2) working.trim() else text
    }

    fun applyFrenchSpacing(text: String): String {
        if (text.isEmpty()) return text
        var out = Regex("\\s*([;:!?»])").replace(text, "\u202F$1")
        out = Regex("«\\s*").replace(out, "«\u202F")
        return out.trim()
    }

    fun format(text: String, options: SpeechFormattingOptions = SpeechFormattingOptions()): String {
        var out = text.trim()
        if (out.isEmpty()) return ""
        if (options.removeFillerWords) {
            out = Regex("(?i)(?<![\\p{L}\\p{N}_])(um+|uh+|er+|ah+)(?![\\p{L}\\p{N}_])[,\\s]*")
                .replace(out, " ")
        }
        if (options.spokenPunctuation) {
            out = applySpokenPunctuation(out)
        }
        if (options.spokenLists) {
            out = applySpokenLists(out)
        }
        if (options.vocabulary.isNotEmpty()) {
            out = applyVocabularySpelling(out, options.vocabulary)
        }
        out = Regex("[ \\t]{2,}").replace(out, " ")
        out = Regex(" *\\n *").replace(out, "\n").trim()
        if (options.frenchSpacing) {
            out = applyFrenchSpacing(out)
        }
        if (options.lowercaseOutput) {
            out = out.lowercase(Locale.ROOT)
        }
        if (options.endWithPeriod && out.isNotEmpty() && out.last() !in setOf('.', '!', '?', '…')) {
            out += "."
        }
        return out
    }
}
