package ai.quenderin.app.contentreport

import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.UUID

enum class ReportSource(val wire: String) {
    LOCAL_CHAT("local-chat"), AGENT("agent"), DEEPSEEK("deepseek"), REMOTE("remote"), STEP5("step5"),
}

enum class ReportReason(val wire: String) {
    HARASSMENT("harassment"), HATE("hate"), SEXUAL("sexual"), VIOLENCE("violence"), DANGEROUS("dangerous"), OTHER("other"),
}

/** The only information approved for transmission. This type cannot attach a conversation or key. */
data class ReportDraft(
    val source: ReportSource,
    val appVersion: String,
    val content: String,
    val note: String = "",
    val reason: ReportReason = ReportReason.OTHER,
    val reportId: String = UUID.randomUUID().toString(),
    val attempted: Boolean = false,
) {
    fun edit(content: String = this.content, note: String = this.note, reason: ReportReason = this.reason): ReportDraft {
        if (content == this.content && note == this.note && reason == this.reason) return this
        return copy(content = content, note = note, reason = reason,
            reportId = if (attempted) UUID.randomUUID().toString() else reportId, attempted = false)
    }
}

data class PreparedReport(val reportId: String, val json: String)

sealed interface ReportResult {
    data class Received(val receiptId: String, val receivedAt: String) : ReportResult
    data class Rejected(val code: String) : ReportResult
    /** No verified receipt: the write might have happened. A manual retry must keep the payload. */
    data object Unconfirmed : ReportResult
    data object Unavailable : ReportResult
}

object ContentReportProtocol {
    const val CONTENT_BYTES = 6000
    const val NOTE_BYTES = 1000
    const val ENVELOPE_BYTES = 8192
    private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private val version = Regex("[A-Za-z0-9][A-Za-z0-9.+_()\\-]{0,63}")
    private val timestamp = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z")
    private val rejectionCodes = setOf("invalid_request", "too_large", "conflict", "unavailable", "method_not_allowed")

    fun prepare(draft: ReportDraft): PreparedReport? {
        if (draft.content.length > CONTENT_BYTES || draft.note.length > NOTE_BYTES ||
            !uuid.matches(draft.reportId) || !version.matches(draft.appVersion) || blankContent(draft.content) ||
            !validUnicode(draft.content) || !validUnicode(draft.note) ||
            draft.content.toByteArray(Charsets.UTF_8).size > CONTENT_BYTES ||
            draft.note.toByteArray(Charsets.UTF_8).size > NOTE_BYTES) return null
        val json = "{\"schema\":1,\"reportId\":${quote(draft.reportId)},\"platform\":\"android\"," +
            "\"appVersion\":${quote(draft.appVersion)},\"source\":${quote(draft.source.wire)}," +
            "\"reason\":${quote(draft.reason.wire)},\"content\":${quote(draft.content)},\"note\":${quote(draft.note)}}"
        // Match the receiver's canonical envelope, including its fixed-length UUID and UTC timestamp.
        val envelope = "{\"schema\":1,\"receiptId\":\"00000000-0000-4000-8000-000000000000\"," +
            "\"receivedAt\":\"2026-01-01T00:00:00.000Z\",\"report\":$json}"
        if (json.toByteArray(Charsets.UTF_8).size > ENVELOPE_BYTES ||
            envelope.toByteArray(Charsets.UTF_8).size > ENVELOPE_BYTES) return null
        return PreparedReport(draft.reportId, json)
    }

    fun receipt(json: String, expectedReportId: String): ReportResult {
        val fields = runCatching { ReceiptReader(json).read() }.getOrNull() ?: return ReportResult.Unconfirmed
        if (fields["ok"] == false && fields.keys == setOf("ok", "code")) {
            val code = fields["code"] as? String
            return if (code in rejectionCodes) ReportResult.Rejected(code!!) else ReportResult.Unconfirmed
        }
        if (fields.keys != setOf("ok", "code", "reportId", "receiptId", "receivedAt") ||
            fields["ok"] != true || fields["code"] != "received" || fields["reportId"] != expectedReportId) return ReportResult.Unconfirmed
        val receipt = fields["receiptId"] as? String ?: return ReportResult.Unconfirmed
        val receivedAt = fields["receivedAt"] as? String ?: return ReportResult.Unconfirmed
        if (!uuid.matches(receipt) || !timestamp.matches(receivedAt) ||
            runCatching { LocalDateTime.parse(receivedAt, DateTimeFormatter
                .ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withResolverStyle(ResolverStyle.STRICT)) }.isFailure)
            return ReportResult.Unconfirmed
        return ReportResult.Received(receipt, receivedAt)
    }

    /** Prefix without splitting a surrogate pair; never silently includes other messages. */
    fun initialExcerpt(text: String): String {
        var bytes = 0
        var index = 0
        while (index < text.length) {
            val point = text.codePointAt(index)
            val width = when { point <= 0x7f -> 1; point <= 0x7ff -> 2; point <= 0xffff -> 3; else -> 4 }
            if (bytes + width > CONTENT_BYTES) break
            bytes += width
            index += Character.charCount(point)
        }
        return text.substring(0, index)
    }

    private fun validUnicode(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            if (char.isHighSurrogate()) {
                if (index >= text.length || !text[index++].isLowSurrogate()) return false
            } else if (char.isLowSurrogate()) return false
        }
        return true
    }

    // The receiver uses ECMAScript trim(), whose whitespace includes the byte-order mark.
    private fun blankContent(text: String): Boolean = text.all { when (it) {
        '\t', '\n', '\u000b', '\u000c', '\r', ' ', '\u00a0', '\u1680',
        '\u2028', '\u2029', '\u202f', '\u205f', '\u3000', '\ufeff' -> true
        in '\u2000'..'\u200a' -> true
        else -> false
    } }

    private fun quote(text: String): String = buildString {
        append('"')
        text.forEach { char -> when (char) {
            '"' -> append("\\\""); '\\' -> append("\\\\"); '\b' -> append("\\b"); '\u000c' -> append("\\f")
            '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
            else -> if (char < ' ') append("\\u%04x".format(char.code)) else append(char)
        } }
        append('"')
    }

    /** Small strict parser for the receipt's flat string/boolean object. Rejects duplicate keys,
     * coercions, lenient JSON, nesting and trailing data rather than accepting an HTML login page. */
    private class ReceiptReader(private val text: String) {
        private var at = 0
        fun read(): Map<String, Any> {
            require(text.length <= ENVELOPE_BYTES)
            expect('{')
            val fields = linkedMapOf<String, Any>()
            space()
            if (peek() != '}') while (true) {
                val key = string()
                require(key !in fields && fields.size < 5)
                expect(':')
                space()
                fields[key] = when (peek()) {
                    '"' -> string()
                    't' -> { literal("true"); true }
                    'f' -> { literal("false"); false }
                    else -> error("Invalid receipt value")
                }
                space()
                if (peek() != ',') break
                at++
            }
            expect('}')
            space()
            require(at == text.length)
            return fields
        }
        private fun string(): String {
            expect('"')
            val result = StringBuilder()
            while (true) {
                require(at < text.length)
                val char = text[at++]
                if (char == '"') break
                require(char >= ' ')
                if (char != '\\') result.append(char) else {
                    require(at < text.length)
                    result.append(when (val escaped = text[at++]) {
                        '"', '\\', '/' -> escaped
                        'b' -> '\b'; 'f' -> '\u000c'; 'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'
                        'u' -> { require(at + 4 <= text.length); val hex = text.substring(at, at + 4)
                            require(hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' })
                            at += 4; hex.toInt(16).toChar() }
                        else -> error("Invalid escape")
                    })
                }
            }
            return result.toString().also { require(validUnicode(it)) }
        }
        private fun literal(value: String) { require(text.startsWith(value, at)); at += value.length }
        private fun peek(): Char? = text.getOrNull(at)
        private fun space() { while (peek() in listOf(' ', '\t', '\r', '\n')) at++ }
        private fun expect(char: Char) { space(); require(peek() == char); at++ }
    }
}
