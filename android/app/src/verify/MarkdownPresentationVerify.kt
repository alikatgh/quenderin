package ai.quenderin.app.ui

/** Pure parser checks; no Android SDK, network, models, or native runtime. */
fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    val code = "\r\n  val text = \"🦊\"\r\n\r\n\tprintln(text)  \r\n"
    val blocks = parseMarkdownBlocks("Before\n\n```kotlin\r\n" + code + "```\r\nAfter")
    verify(blocks.filterIsInstance<MdCodeBlock>().single().code == code)
    verify(parseMarkdownBlocks("```\n\n\n``` ").filterIsInstance<MdCodeBlock>().single().code == "\n\n")
    verify(parseMarkdownBlocks("```\n  no closing fence").filterIsInstance<MdCodeBlock>().single().code == "  no closing fence")
    val raw = "a".repeat(16_383) + "🦊" + "\r\n" + "b".repeat(70_000)
    val sections = remoteTextSections(raw)
    verify(sections.joinToString("") == raw && sections.all { it.length <= 16_384 })
    verify(sections.none { it.first().isLowSurrogate() || it.last().isHighSurrogate() })
    val preview = remoteTextPreview("a".repeat(2_047) + "🦊" + "remaining")
    verify(preview == "a".repeat(2_047))
    verify(remoteTextSections("") == listOf("") && remoteTextPreview(" small ") == " small ")
    verify(markdownInlineFormattingAllowed("**Answer** with [a link](https://example.org) and `code`"))
    val malformed = "[".repeat(2 * 1_024 * 1_024)
    verify(!markdownInlineFormattingAllowed(malformed) && !remoteMarkdownFormattingAllowed(malformed))
    verify(!markdownInlineFormattingAllowed("[".repeat(2_048) + "]](https://example.org)"))
    verify(!remoteMarkdownFormattingAllowed("plain response ".repeat(2_048)))
    verify(remoteTextSections(malformed).all { it.length <= 16_384 } && remoteTextSections(malformed).joinToString("") == malformed)
    println("Android Markdown presentation: $checks checks passed (pure parser, no rendered/native evidence).")
}
