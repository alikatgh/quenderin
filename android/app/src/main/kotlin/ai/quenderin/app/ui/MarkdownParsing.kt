package ai.quenderin.app.ui

// ── Block model ──────────────────────────────────────────────────────────────
internal sealed interface MdBlock
internal data class MdHeading(val level: Int, val text: String) : MdBlock
internal data class MdParagraph(val text: String) : MdBlock
internal data class MdCodeBlock(val code: String) : MdBlock
internal data class MdList(val items: List<String>, val ordered: Boolean, val start: Int) : MdBlock
internal data class MdQuote(val text: String) : MdBlock
internal data object MdRule : MdBlock

internal val HEADING = Regex("^(#{1,6})\\s+(.*)$")
internal val BULLET = Regex("^\\s*[-*+]\\s+(.*)$")
internal val ORDERED = Regex("^\\s*(\\d+)[.)]\\s+(.*)$")
internal val RULE = Regex("^\\s*([-*_])\\1{2,}\\s*$")
internal val QUOTE = Regex("^>\\s?(.*)$")

/** Split raw text into block-level Markdown elements. Line-oriented; a blank line separates blocks. */
internal fun parseMarkdownBlocks(text: String): List<MdBlock> {
    val rawLines = text.split("\n")
    val lines = rawLines.map { it.removeSuffix("\r") }
    val offsets = IntArray(lines.size)
    for (index in 1 until lines.size) offsets[index] = offsets[index - 1] + rawLines[index - 1].length + 1
    val blocks = mutableListOf<MdBlock>()
    var i = 0
    val para = StringBuilder()
    fun flushPara() {
        if (para.isNotEmpty()) { blocks.add(MdParagraph(para.toString().trim())); para.clear() }
    }
    while (i < lines.size) {
        val line = lines[i]
        when {
            // Fenced code block: ``` … ```
            line.trimStart().startsWith("```") -> {
                flushPara()
                i++
                val contentStart = if (i < lines.size) offsets[i] else text.length
                while (i < lines.size && !lines[i].trimStart().startsWith("```")) i++
                val contentEnd = if (i < lines.size) offsets[i] else text.length
                blocks.add(MdCodeBlock(text.substring(contentStart, contentEnd)))
                if (i < lines.size) i++
            }
            line.isBlank() -> { flushPara(); i++ }
            RULE.matches(line) -> { flushPara(); blocks.add(MdRule); i++ }
            HEADING.matches(line) -> {
                flushPara()
                val m = HEADING.find(line)!!
                blocks.add(MdHeading(m.groupValues[1].length, m.groupValues[2].trim()))
                i++
            }
            BULLET.matches(line) -> {
                flushPara()
                val items = mutableListOf<String>()
                while (i < lines.size && BULLET.matches(lines[i])) {
                    items.add(BULLET.find(lines[i])!!.groupValues[1]); i++
                }
                blocks.add(MdList(items, ordered = false, start = 1))
            }
            ORDERED.matches(line) -> {
                flushPara()
                val first = ORDERED.find(line)!!.groupValues[1].toIntOrNull() ?: 1
                val items = mutableListOf<String>()
                while (i < lines.size && ORDERED.matches(lines[i])) {
                    items.add(ORDERED.find(lines[i])!!.groupValues[2]); i++
                }
                blocks.add(MdList(items, ordered = true, start = first))
            }
            QUOTE.matches(line) -> {
                flushPara()
                val buf = StringBuilder()
                while (i < lines.size && QUOTE.matches(lines[i])) {
                    if (buf.isNotEmpty()) buf.append(" ")
                    buf.append(QUOTE.find(lines[i])!!.groupValues[1]); i++
                }
                blocks.add(MdQuote(buf.toString().trim()))
            }
            else -> {
                if (para.isNotEmpty()) para.append(" ")
                para.append(line.trim()); i++
            }
        }
    }
    flushPara()
    return blocks
}


/** Bound raw transcript layout while preserving every UTF-16 scalar in the original copy. */
internal fun remoteTextSections(text: String, maximum: Int = 16_384): List<String> {
    require(maximum >= 2)
    if (text.isEmpty()) return listOf("")
    val sections = ArrayList<String>()
    var start = 0
    while (start < text.length) {
        var end = (start + maximum).coerceAtMost(text.length)
        if (end < text.length && text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end--
        sections.add(text.substring(start, end)); start = end
    }
    return sections
}
internal fun remoteTextPreview(text: String): String {
    if (text.length <= 2_048) return text
    var end = 2_048
    if (text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end--
    return text.substring(0, end)
}

/** Untrusted malformed delimiters must not trigger repeated suffix scans or deep recursion.
 * Over-budget input remains exact plain text; Remote uses its paginated raw viewer. */
internal fun markdownInlineFormattingAllowed(text: String): Boolean {
    if (text.length > 16_384) return false
    var markers = 0
    for (character in text) {
        if (character == '[' || character == '*' || character == '_' || character == '`') {
            if (++markers > 128) return false
        }
    }
    return true
}
internal fun remoteMarkdownFormattingAllowed(text: String): Boolean = markdownInlineFormattingAllowed(text)
