package ai.quenderin.app.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.TextButton
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.unit.TextUnit
import ai.quenderin.core.MarkdownLinkPolicy
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A minimal, dependency-free Markdown renderer for chat replies. Models emit Markdown (headings,
 * **bold**, lists, `code`, fenced blocks), and rendering it raw litters the bubble with `*`, `#`, and
 * backtick markers. This turns the common LLM subset into real formatting — ATX headings, bold/italic,
 * inline + fenced code, bullet/numbered lists, blockquotes, links, and rules. NOT a full CommonMark
 * engine (no tables/nested lists), but it covers assistant output and degrades gracefully (an
 * unmatched marker just renders literally). Twin of iOS `MarkdownText`.
 */
@Composable
fun MarkdownText(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    baseStyle: TextStyle = MaterialTheme.typography.bodyLarge,
    wrapCode: Boolean = false,
    codeFontSize: TextUnit = 13.sp,
    showsCodeCopyButton: Boolean = false,
) {
    val codeBg = color.copy(alpha = 0.10f)
    val linkColor = MaterialTheme.colorScheme.primary
    val blocks = remember(text) { parseMarkdownBlocks(text) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        blocks.forEach { block ->
            when (block) {
                is MdHeading -> Text(
                    inline(block.text, codeBg, linkColor),
                    color = color,
                    style = headingStyle(block.level),
                )
                is MdParagraph -> Text(inline(block.text, codeBg, linkColor), color = color, style = baseStyle)
                is MdCodeBlock -> CodeBlock(block.code, color, codeBg, wrapCode, codeFontSize, showsCodeCopyButton)
                is MdList -> Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    block.items.forEachIndexed { i, item ->
                        Row {
                            Text(
                                if (block.ordered) "${block.start + i}. " else "•  ",
                                color = color,
                                style = baseStyle,
                            )
                            Text(inline(item, codeBg, linkColor), color = color, style = baseStyle, modifier = Modifier.weight(1f))
                        }
                    }
                }
                is MdQuote -> Text(
                    inline(block.text, codeBg, linkColor),
                    color = color.copy(alpha = 0.85f),
                    style = baseStyle.copy(fontStyle = FontStyle.Italic),
                    modifier = Modifier.padding(start = 10.dp),
                )
                MdRule -> androidx.compose.material3.HorizontalDivider(color = color.copy(alpha = 0.2f))
            }
        }
    }
}

@Composable
private fun CodeBlock(code: String, color: Color, bg: Color, wrap: Boolean, fontSize: TextUnit, showsCopy: Boolean) {
    val clipboard = LocalClipboardManager.current
    Surface(color = bg, shape = RoundedCornerShape(10.dp), modifier = Modifier.fillMaxWidth()) {
        Column {
            if (showsCopy) TextButton(onClick = { clipboard.setText(AnnotatedString(code)) }) { Text("Copy code") }
            SelectionContainer {
                Text(code, color = color,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace, fontSize = fontSize),
                    modifier = Modifier.then(if (wrap) Modifier else Modifier.horizontalScroll(rememberScrollState()))
                        .padding(horizontal = 12.dp, vertical = 10.dp))
            }
        }
    }
}

@Composable
private fun headingStyle(level: Int): TextStyle = when (level) {
    1 -> MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
    2 -> MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
    else -> MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold)
}

// ── Inline parsing → AnnotatedString ────────────────────────────────────────
/** Parse inline Markdown (**bold**, *italic*, `code`, [text](url)) into a styled string. */
private fun inline(s: String, codeBg: Color, linkColor: Color): AnnotatedString {
    if (!markdownInlineFormattingAllowed(s)) return AnnotatedString(s)
    return buildAnnotatedString { appendInline(s, codeBg, linkColor) }
}

private fun androidx.compose.ui.text.AnnotatedString.Builder.appendInline(s: String, codeBg: Color, linkColor: Color, depth: Int = 0) {
    if (depth >= 16) { append(s); return }
    var i = 0
    fun isWordChar(c: Char) = c.isLetterOrDigit()
    while (i < s.length) {
        val c = s[i]
        when {
            // inline code: `code`
            c == '`' -> {
                val end = s.indexOf('`', i + 1)
                if (end == -1) { append(c); i++ }
                else {
                    pushStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBg))
                    append(s.substring(i + 1, end))
                    pop()
                    i = end + 1
                }
            }
            // bold: **text** or __text__
            (s.startsWith("**", i) || s.startsWith("__", i)) -> {
                val marker = s.substring(i, i + 2)
                val end = s.indexOf(marker, i + 2)
                if (end == -1) { append(c); i++ }
                else {
                    pushStyle(SpanStyle(fontWeight = FontWeight.Bold))
                    appendInline(s.substring(i + 2, end), codeBg, linkColor, depth + 1)
                    pop()
                    i = end + 2
                }
            }
            // italic: *text* (or _text_ only when not mid-word, to spare snake_case)
            (c == '*' || (c == '_' && (i == 0 || !isWordChar(s[i - 1])))) -> {
                val end = s.indexOf(c, i + 1)
                if (end == -1 || end == i + 1) { append(c); i++ }
                else {
                    pushStyle(SpanStyle(fontStyle = FontStyle.Italic))
                    appendInline(s.substring(i + 1, end), codeBg, linkColor, depth + 1)
                    pop()
                    i = end + 1
                }
            }
            // link: [text](url)
            c == '[' -> {
                val close = s.indexOf(']', i + 1)
                if (close != -1 && close + 1 < s.length && s[close + 1] == '(') {
                    val urlEnd = s.indexOf(')', close + 2)
                    if (urlEnd != -1) {
                        val label = s.substring(i + 1, close)
                        val url = s.substring(close + 2, urlEnd)
                        if (MarkdownLinkPolicy.allows(url)) withLink(
                            LinkAnnotation.Url(
                                url,
                                styles = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)),
                            ),
                        ) { appendInline(label, codeBg, linkColor, depth + 1) }
                        else append(s.substring(i, urlEnd + 1))
                        i = urlEnd + 1
                    } else { append(c); i++ }
                } else { append(c); i++ }
            }
            else -> { append(c); i++ }
        }
    }
}
