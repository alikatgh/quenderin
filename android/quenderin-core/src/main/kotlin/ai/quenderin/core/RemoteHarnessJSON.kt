package ai.quenderin.core

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Collections

object RemoteHarnessBounds {
    const val FRAME_BYTES = 4_194_304
    const val JSON_DEPTH = 32
    const val CONTAINER_ENTRIES = 1_024
    const val PENDING_RPC = 128
    const val STREAMS = 16
    const val DEADLINE_MS = 120_000L
    const val TEXT_BYTES = 65_536
    const val SAFE_INTEGER = 9_007_199_254_740_991L
}

/** Only fixed local codes enter exceptions; never remote diagnostics or user content. */
class RemoteHarnessException(val code: String) : IllegalArgumentException("Remote Harness: $code")
internal fun rhCheck(value: Boolean, code: String = "invalid-frame") {
    if (!value) throw RemoteHarnessException(code)
}
internal fun rhID(value: String) {
    rhCheck(value.isNotEmpty() && value.length <= 256 && value.none { it.code < 32 || it.code == 127 }, "invalid-id")
    rhUnicode(value)
}
internal fun rhUnicode(value: String) {
    var index = 0
    while (index < value.length) {
        val c = value[index++]
        if (c.isHighSurrogate()) {
            rhCheck(index < value.length && value[index].isLowSurrogate(), "invalid-unicode")
            index++
        } else rhCheck(!c.isLowSurrogate(), "invalid-unicode")
    }
}

/** Immutable JSON preserves unknown fields and number lexemes; toString never exposes content. */
sealed class RemoteHarnessJSON {
    final override fun toString() = "RemoteHarnessJSON(redacted)"
    class ObjectValue private constructor(values: Map<String, RemoteHarnessJSON>, internal val sourceUTF8Bytes: Int?) : RemoteHarnessJSON() {
        constructor(values: Map<String, RemoteHarnessJSON>) : this(values, null)
        val values: Map<String, RemoteHarnessJSON> = run {
            rhCheck(values.size <= RemoteHarnessBounds.CONTAINER_ENTRIES, "container-limit"); values.keys.forEach(::rhUnicode)
            Collections.unmodifiableMap(LinkedHashMap(values))
        }
        companion object {
            /** Exact original object span, including internal whitespace and escape spelling.
             * Metadata is immutable, never serialized, and absent for programmatically built trees. */
            internal fun parsed(values: Map<String, RemoteHarnessJSON>, sourceUTF8Bytes: Int) = ObjectValue(values, sourceUTF8Bytes)
        }
    }
    class ArrayValue(values: List<RemoteHarnessJSON>) : RemoteHarnessJSON() {
        val values: List<RemoteHarnessJSON> = run {
            rhCheck(values.size <= RemoteHarnessBounds.CONTAINER_ENTRIES, "container-limit")
            Collections.unmodifiableList(ArrayList(values))
        }
    }
    class StringValue(val value: String) : RemoteHarnessJSON() {
        init { rhCheck(value.length <= RemoteHarnessBounds.FRAME_BYTES, "frame-limit"); rhUnicode(value) }
    }
    class NumberValue(val token: String) : RemoteHarnessJSON() {
        init { rhCheck(token.length <= RemoteHarnessBounds.FRAME_BYTES && NUMBER.matches(token), "invalid-json") }
    }
    class BooleanValue(val value: Boolean) : RemoteHarnessJSON()
    object NullValue : RemoteHarnessJSON()

    fun objectValue(): Map<String, RemoteHarnessJSON> = (this as? ObjectValue)?.values ?: throw RemoteHarnessException("invalid-type")
    fun stringValue(): String = (this as? StringValue)?.value ?: throw RemoteHarnessException("invalid-type")
    fun booleanValue(): Boolean = (this as? BooleanValue)?.value ?: throw RemoteHarnessException("invalid-type")
    fun integerValue(positive: Boolean = false): Long {
        val token = (this as? NumberValue)?.token ?: throw RemoteHarnessException("invalid-type")
        rhCheck(token.isNotEmpty() && token.all { it in '0'..'9' }, "invalid-counter")
        val number = token.toLongOrNull() ?: throw RemoteHarnessException("invalid-counter")
        rhCheck(number in (if (positive) 1L else 0L)..RemoteHarnessBounds.SAFE_INTEGER, "invalid-counter")
        return number
    }

    companion object {
        private val NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
        fun obj(vararg pairs: Pair<String, RemoteHarnessJSON?>): ObjectValue = ObjectValue(linkedMapOf<String, RemoteHarnessJSON>().apply {
            pairs.forEach { (key, value) -> if (value != null) put(key, value) }
        })
        fun str(value: String) = StringValue(value)
        fun num(value: Long) = NumberValue(value.toString())
        internal fun decodeUTF8(bytes: ByteArray): String {
            rhCheck(bytes.size <= RemoteHarnessBounds.FRAME_BYTES, "frame-limit")
            val source = try {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) { throw RemoteHarnessException("invalid-utf8") }
            return source
        }
        fun parse(bytes: ByteArray): RemoteHarnessJSON = parse(decodeUTF8(bytes))
        fun parse(source: String): RemoteHarnessJSON {
            rhCheck(source.length <= RemoteHarnessBounds.FRAME_BYTES, "frame-limit")
            rhUnicode(source)
            rhCheck(source.toByteArray(Charsets.UTF_8).size <= RemoteHarnessBounds.FRAME_BYTES, "frame-limit")
            return Reader(source).read()
        }
        fun write(value: RemoteHarnessJSON): String {
            val out = StringBuilder()
            var bytes = 0
            fun append(s: String) {
                bytes += s.toByteArray(Charsets.UTF_8).size
                rhCheck(bytes <= RemoteHarnessBounds.FRAME_BYTES, "frame-limit")
                out.append(s)
            }
            fun quoted(s: String) {
                append("\"")
                // Each chunk is at most one Unicode scalar, so budget accounting is exact.
                var i = 0
                while (i < s.length) {
                    val c = s[i++]
                    append(when (c) {
                        '"' -> "\\\""; '\\' -> "\\\\"; '\b' -> "\\b"; '\u000c' -> "\\f"
                        '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"
                        else -> if (c.code < 32) "\\u" + c.code.toString(16).padStart(4, '0')
                            else if (c.isHighSurrogate()) "$c${s[i++]}" else c.toString()
                    })
                }
                append("\"")
            }
            fun visit(v: RemoteHarnessJSON, depth: Int) {
                rhCheck(depth <= RemoteHarnessBounds.JSON_DEPTH, "json-depth")
                when (v) {
                    is ObjectValue -> { append("{"); v.values.entries.forEachIndexed { i, e -> if (i != 0) append(","); quoted(e.key); append(":"); visit(e.value, depth + 1) }; append("}") }
                    is ArrayValue -> { append("["); v.values.forEachIndexed { i, item -> if (i != 0) append(","); visit(item, depth + 1) }; append("]") }
                    is StringValue -> quoted(v.value)
                    is NumberValue -> append(v.token)
                    is BooleanValue -> append(if (v.value) "true" else "false")
                    NullValue -> append("null")
                }
            }
            visit(value, 1)
            return out.toString()
        }
    }

    private class Reader(private val source: String) {
        private var position = 0
        private var utf8Position = 0
        private fun advance(): Char {
            val c = source[position++]
            // parse() already validates raw scalar pairs. Count their UTF-8 bytes once, while
            // escaped Unicode remains the ASCII bytes actually carried in the source.
            utf8Position += when {
                c.code <= 0x7f -> 1
                c.code <= 0x7ff -> 2
                c.isHighSurrogate() -> 4
                c.isLowSurrogate() -> 0
                else -> 3
            }
            return c
        }
        fun read(): RemoteHarnessJSON { val value = value(1); whitespace(); rhCheck(position == source.length, "invalid-json"); return value }
        private fun whitespace() { while (position < source.length && source[position] in " \t\r\n") advance() }
        private fun take(c: Char): Boolean = if (position < source.length && source[position] == c) { advance(); true } else false
        private fun expect(c: Char) = rhCheck(take(c), "invalid-json")
        private fun value(depth: Int): RemoteHarnessJSON {
            rhCheck(depth <= RemoteHarnessBounds.JSON_DEPTH, "json-depth"); whitespace()
            rhCheck(position < source.length, "invalid-json")
            return when (source[position]) {
                '{' -> {
                    val startBytes = utf8Position
                    advance(); whitespace(); val map = linkedMapOf<String, RemoteHarnessJSON>()
                    if (!take('}')) { do {
                        whitespace(); val key = quoted(); rhCheck(!map.containsKey(key), "duplicate-key")
                        rhCheck(map.size < RemoteHarnessBounds.CONTAINER_ENTRIES, "container-limit")
                        whitespace(); expect(':'); map[key] = value(depth + 1); whitespace()
                    } while (take(',')); expect('}') }; ObjectValue.parsed(map, utf8Position - startBytes)
                }
                '[' -> {
                    advance(); whitespace(); val list = arrayListOf<RemoteHarnessJSON>()
                    if (!take(']')) { do {
                        rhCheck(list.size < RemoteHarnessBounds.CONTAINER_ENTRIES, "container-limit")
                        list.add(value(depth + 1)); whitespace()
                    } while (take(',')); expect(']') }; ArrayValue(list)
                }
                '"' -> StringValue(quoted())
                't' -> { literal("true"); BooleanValue(true) }
                'f' -> { literal("false"); BooleanValue(false) }
                'n' -> { literal("null"); NullValue }
                '-', in '0'..'9' -> number()
                else -> throw RemoteHarnessException("invalid-json")
            }
        }
        private fun literal(token: String) {
            rhCheck(source.regionMatches(position, token, 0, token.length), "invalid-json")
            position += token.length; utf8Position += token.length
        }
        private fun number(): NumberValue {
            val start = position; take('-'); rhCheck(position < source.length, "invalid-json")
            if (!take('0')) { rhCheck(source[position] in '1'..'9', "invalid-json"); digits() }
            if (take('.')) { val startDigits = position; digits(); rhCheck(position > startDigits, "invalid-json") }
            if (take('e') || take('E')) { if (!take('+')) take('-'); val startDigits = position; digits(); rhCheck(position > startDigits, "invalid-json") }
            return NumberValue(source.substring(start, position))
        }
        private fun digits() { while (position < source.length && source[position] in '0'..'9') advance() }
        private fun quoted(): String {
            expect('"'); val out = StringBuilder(); var closed = false
            while (position < source.length) {
                val c = advance()
                if (c == '"') { closed = true; break }
                rhCheck(c.code >= 32, "invalid-json")
                if (c != '\\') out.append(c) else {
                    rhCheck(position < source.length, "invalid-json")
                    when (val escape = advance()) {
                        '"', '\\', '/' -> out.append(escape)
                        'b' -> out.append('\b'); 'f' -> out.append('\u000c'); 'n' -> out.append('\n'); 'r' -> out.append('\r'); 't' -> out.append('\t')
                        'u' -> {
                            rhCheck(position + 4 <= source.length, "invalid-json")
                            val token = source.substring(position, position + 4)
                            rhCheck(token.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }, "invalid-json")
                            out.append(token.toInt(16).toChar()); position += 4; utf8Position += 4
                        }
                        else -> throw RemoteHarnessException("invalid-json")
                    }
                }
            }
            rhCheck(closed, "invalid-json"); return out.toString().also(::rhUnicode)
        }
    }
}

internal fun Map<String, RemoteHarnessJSON>.rhRequired(key: String) = this[key] ?: throw RemoteHarnessException("missing-field")
internal fun Map<String, RemoteHarnessJSON>.rhString(key: String) = rhRequired(key).stringValue()
internal fun Map<String, RemoteHarnessJSON>.rhFields(vararg keys: String) = rhCheck(this.keys.all { it in keys }, "unknown-field")
