package ai.quenderin.core

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.Inflater

/**
 * Turns a user-picked file into an [AttachedDocument] at attach time (Milestone 1 — documents in
 * chat). Plain text (strict UTF-8 — binary refused, never mangled) and **PDF text** via a
 * dependency-free content-stream parser (BT/ET · Tj/TJ/'/" · FlateDecode). Twin of iOS
 * `DocumentTextExtractor` (PDFKit there). Both capped so one attachment can't blow the model's
 * context. Scanned / image-only PDFs are refused honestly — OCR is out of scope for on-device v1.
 */
object DocumentTextExtractor {
    sealed interface Extraction {
        data class Document(val document: AttachedDocument) : Extraction
        data class Rejected(val reason: String) : Extraction
    }

    /** 24 KB default: enough for READMEs/configs/notes, small enough that a 2048-token context
     *  (a phone under pressure) still has room to answer about it. */
    private const val DEFAULT_MAX_BYTES = 24 * 1024

    /** Hard cap on raw PDF bytes loaded into memory (structure + streams). Text output still
     *  stops at [maxBytes]; this only bounds peak RAM for a hostile multi-hundred-MB file. */
    private const val PDF_RAW_CAP = 8 * 1024 * 1024

    @JvmOverloads
    fun extract(name: String, file: File, maxBytes: Int = DEFAULT_MAX_BYTES): Extraction {
        if (!file.isFile) return Extraction.Rejected("Couldn't open \"$name\".")
        if (isPdfName(name)) {
            val bytes = try {
                file.inputStream().use { it.readNBytes(PDF_RAW_CAP + 1) }
            } catch (_: Throwable) {
                return Extraction.Rejected("Couldn't read \"$name\".")
            }
            if (bytes.size > PDF_RAW_CAP) {
                return Extraction.Rejected(
                    "\"$name\" is larger than ${PDF_RAW_CAP / (1024 * 1024)} MB — attach a smaller PDF.",
                )
            }
            return extractPdf(name, bytes, maxBytes)
        }
        val bytes = try {
            file.inputStream().use { it.readNBytes(maxBytes + 1) }
        } catch (_: Throwable) {
            return Extraction.Rejected("Couldn't read \"$name\".")
        }
        return extract(name, bytes, maxBytes)
    }

    /**
     * Extract from raw bytes (SAF content:// streams after a one-shot read). Same UTF-8 gate,
     * PDF path, and cap as the [File] overload — the Compose attach path uses this so a content
     * URI never has to be copied to disk before chat can use it.
     */
    @JvmOverloads
    fun extract(name: String, bytes: ByteArray, maxBytes: Int = DEFAULT_MAX_BYTES): Extraction {
        if (bytes.isEmpty()) return Extraction.Rejected("\"$name\" is empty.")
        if (isPdfName(name) || looksLikePdf(bytes)) {
            if (bytes.size > PDF_RAW_CAP) {
                return Extraction.Rejected(
                    "\"$name\" is larger than ${PDF_RAW_CAP / (1024 * 1024)} MB — attach a smaller PDF.",
                )
            }
            return extractPdf(name, bytes, maxBytes)
        }
        val truncated = bytes.size > maxBytes
        val slice = if (truncated) bytes.copyOf(maxBytes) else bytes
        val text = try {
            // Strict UTF-8: REPORT on malformed (binary → Rejected, never mangled with �).
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            decoder.decode(java.nio.ByteBuffer.wrap(slice)).toString()
        } catch (_: Throwable) {
            return Extraction.Rejected(
                "\"$name\" isn't a text file — only text and PDF attachments are supported for now.",
            )
        }
        val body = if (truncated) text + "\n[…file truncated at ${maxBytes / 1024} KB]" else text
        return Extraction.Document(AttachedDocument(name, body))
    }

    private fun isPdfName(name: String): Boolean = name.lowercase().endsWith(".pdf")

    private fun looksLikePdf(bytes: ByteArray): Boolean {
        if (bytes.size < 5) return false
        return bytes[0] == '%'.code.toByte() &&
            bytes[1] == 'P'.code.toByte() &&
            bytes[2] == 'D'.code.toByte() &&
            bytes[3] == 'F'.code.toByte() &&
            bytes[4] == '-'.code.toByte()
    }

    /**
     * PDF → text from content streams, stopping once the cap is reached. A PDF with no
     * extractable text (scans) is refused honestly — OCR is out of scope for on-device v1.
     *
     * Parser scope (intentional, not a full PDF engine):
     * - literal `(…)` and hex `<…>` strings under Tj / TJ / ' / "
     * - `/FlateDecode` (and `/Filter [/FlateDecode]`) stream bodies via [Inflater]
     * - does NOT do ToUnicode CMaps, CID fonts, or encrypted PDFs — those yield empty → reject
     */
    private fun extractPdf(name: String, bytes: ByteArray, maxBytes: Int): Extraction {
        if (!looksLikePdf(bytes)) {
            return Extraction.Rejected("Couldn't open \"$name\" as a PDF.")
        }
        val text = try {
            collectPdfText(bytes, maxBytes + 1)
        } catch (_: Throwable) {
            return Extraction.Rejected("Couldn't open \"$name\" as a PDF.")
        }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            return Extraction.Rejected(
                "\"$name\" has no extractable text (a scanned PDF?) — OCR isn't supported yet.",
            )
        }
        var body = trimmed
        val truncated = body.toByteArray(Charsets.UTF_8).size > maxBytes
        if (truncated) {
            // Trim by UTF-8 bytes so we never cut mid-character under the cap.
            val raw = body.toByteArray(Charsets.UTF_8)
            var end = maxBytes.coerceAtMost(raw.size)
            while (end > 0 && (raw[end - 1].toInt() and 0xC0) == 0x80) end--
            if (end > 0 && (raw[end - 1].toInt() and 0xC0) == 0xC0) end--
            body = String(raw, 0, end, Charsets.UTF_8) +
                "\n[…PDF truncated at ${maxBytes / 1024} KB]"
        }
        return Extraction.Document(AttachedDocument(name, body))
    }

    /**
     * Walk the file for `stream`…`endstream` pairs. For each, peek the preceding dictionary
     * for FlateDecode, inflate if needed, then harvest text operators until [limit] UTF-8
     * bytes of text are collected.
     */
    private fun collectPdfText(pdf: ByteArray, limit: Int): String {
        val out = StringBuilder()
        var i = 0
        val n = pdf.size
        while (i < n && out.length < limit) {
            // Match keyword "stream" as a whole token (not inside /Stream or names).
            val streamAt = indexOfToken(pdf, i, "stream")
            if (streamAt < 0) break
            // Dictionary for this stream sits just before "stream".
            val dictStart = pdf.lastIndexOf("<<".toByteArray(Charsets.ISO_8859_1), streamAt)
            val flate = if (dictStart >= 0) {
                val dict = String(pdf, dictStart, streamAt - dictStart, Charsets.ISO_8859_1)
                dict.contains("/FlateDecode")
            } else {
                false
            }
            // Skip "stream" + the mandatory EOL (CR, LF, or CRLF).
            var dataStart = streamAt + 6
            if (dataStart < n && pdf[dataStart] == '\r'.code.toByte()) dataStart++
            if (dataStart < n && pdf[dataStart] == '\n'.code.toByte()) dataStart++
            val endAt = indexOfToken(pdf, dataStart, "endstream")
            if (endAt < 0) break
            // Trim a trailing CR/LF that some writers put before endstream.
            var dataEnd = endAt
            if (dataEnd > dataStart && pdf[dataEnd - 1] == '\n'.code.toByte()) dataEnd--
            if (dataEnd > dataStart && pdf[dataEnd - 1] == '\r'.code.toByte()) dataEnd--
            if (dataEnd > dataStart) {
                val raw = pdf.copyOfRange(dataStart, dataEnd)
                val content = if (flate) inflate(raw) else raw
                if (content != null && content.isNotEmpty()) {
                    harvestTextOperators(content, out, limit)
                }
            }
            i = endAt + 9
        }
        return out.toString()
    }

    private fun inflate(raw: ByteArray): ByteArray? {
        // PDF FlateDecode is zlib-wrapped deflate; some writers emit raw deflate.
        inflateWith(raw, nowrap = false)?.let { return it }
        return inflateWith(raw, nowrap = true)
    }

    private fun inflateWith(raw: ByteArray, nowrap: Boolean): ByteArray? {
        val inflater = Inflater(nowrap)
        return try {
            inflater.setInput(raw)
            val bout = ByteArrayOutputStream(raw.size.coerceAtLeast(256))
            val buf = ByteArray(4096)
            // Cap inflated size so a zip-bomb PDF can't OOM us (output text is still limited).
            val maxInflated = PDF_RAW_CAP
            while (!inflater.finished() && bout.size() < maxInflated) {
                val count = inflater.inflate(buf)
                if (count == 0) {
                    if (inflater.needsInput()) break
                    if (inflater.needsDictionary()) break
                } else {
                    bout.write(buf, 0, count)
                }
            }
            if (bout.size() == 0) null else bout.toByteArray()
        } catch (_: Throwable) {
            null
        } finally {
            inflater.end()
        }
    }

    /**
     * Scan a content stream for PDF text-showing operators. Intentionally tolerant: skips
     * unknown tokens; only cares about strings consumed by Tj / TJ / ' / ".
     */
    private fun harvestTextOperators(content: ByteArray, out: StringBuilder, limit: Int) {
        var i = 0
        val n = content.size
        while (i < n && out.length < limit) {
            when (content[i].toInt().toChar()) {
                '(' -> {
                    val (s, next) = readLiteralString(content, i)
                    i = next
                    // Look ahead for operator after optional whitespace.
                    val op = peekOperator(content, i)
                    when (op) {
                        "Tj", "'", "\"" -> {
                            out.append(s)
                            if (op == "'" || op == "\"") out.append('\n')
                        }
                        "TJ" -> {
                            // Single string before TJ is rare but legal; treat as text.
                            out.append(s)
                        }
                    }
                }
                '<' -> {
                    // Hex string <…> or dict <<…>>.
                    if (i + 1 < n && content[i + 1] == '<'.code.toByte()) {
                        i += 2
                        continue
                    }
                    val (s, next) = readHexString(content, i)
                    i = next
                    val op = peekOperator(content, i)
                    if (op == "Tj" || op == "'" || op == "\"" || op == "TJ") {
                        out.append(s)
                        if (op == "'" || op == "\"") out.append('\n')
                    }
                }
                '[' -> {
                    // TJ array: [(Hello) -20 (World)] TJ
                    val (s, next) = readTjArray(content, i)
                    i = next
                    val op = peekOperator(content, i)
                    if (op == "TJ" || op == "Tj") {
                        out.append(s)
                    }
                }
                else -> i++
            }
        }
    }

    private fun peekOperator(content: ByteArray, start: Int): String? {
        var i = start
        val n = content.size
        while (i < n && content[i].isPdfWhitespace()) i++
        if (i >= n) return null
        val c = content[i].toInt().toChar()
        // Operators are name-like tokens without leading slash.
        if (!c.isLetter() && c != '\'' && c != '"') return null
        val begin = i
        if (c == '\'' || c == '"') return c.toString()
        i++
        while (i < n) {
            val ch = content[i].toInt().toChar()
            if (ch.isLetterOrDigit() || ch == '*') i++
            else break
        }
        return String(content, begin, i - begin, Charsets.ISO_8859_1)
    }

    private fun readLiteralString(content: ByteArray, openParen: Int): Pair<String, Int> {
        // openParen points at '('.
        val sb = StringBuilder()
        var i = openParen + 1
        var depth = 1
        val n = content.size
        while (i < n && depth > 0) {
            when (val b = content[i]) {
                '('.code.toByte() -> {
                    depth++
                    sb.append('(')
                    i++
                }
                ')'.code.toByte() -> {
                    depth--
                    if (depth > 0) sb.append(')')
                    i++
                }
                '\\'.code.toByte() -> {
                    i++
                    if (i >= n) break
                    when (val e = content[i].toInt().toChar()) {
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000c')
                        '(', ')', '\\' -> sb.append(e)
                        '\n' -> { /* line continuation */ }
                        '\r' -> {
                            if (i + 1 < n && content[i + 1] == '\n'.code.toByte()) i++
                        }
                        in '0'..'7' -> {
                            var oct = e - '0'
                            var count = 1
                            while (count < 3 && i + 1 < n) {
                                val d = content[i + 1].toInt().toChar()
                                if (d !in '0'..'7') break
                                i++
                                oct = (oct shl 3) + (d - '0')
                                count++
                            }
                            sb.append(oct.toChar())
                        }
                        else -> sb.append(e)
                    }
                    i++
                }
                else -> {
                    // PDF literal strings are typically PDFDocEncoding / WinAnsi for simple
                    // Latin text — ISO-8859-1 is a reasonable stand-in for the byte→char map.
                    sb.append(b.toInt().toChar())
                    i++
                }
            }
        }
        return sb.toString() to i
    }

    private fun readHexString(content: ByteArray, openAngle: Int): Pair<String, Int> {
        // openAngle points at '<'.
        var i = openAngle + 1
        val n = content.size
        val hex = StringBuilder()
        while (i < n) {
            val c = content[i].toInt().toChar()
            if (c == '>') {
                i++
                break
            }
            if (c in '0'..'9' || c in 'A'..'F' || c in 'a'..'f') hex.append(c)
            // whitespace inside hex strings is ignored per PDF spec
            i++
        }
        if (hex.length % 2 == 1) hex.append('0')
        val bytes = ByteArray(hex.length / 2)
        var h = 0
        while (h < hex.length) {
            bytes[h / 2] = hex.substring(h, h + 2).toInt(16).toByte()
            h += 2
        }
        // Prefer UTF-8 when valid; else Latin-1 so we still surface something.
        val text = try {
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (_: Throwable) {
            String(bytes, Charsets.ISO_8859_1)
        }
        return text to i
    }

    private fun readTjArray(content: ByteArray, openBracket: Int): Pair<String, Int> {
        // openBracket points at '['.
        val sb = StringBuilder()
        var i = openBracket + 1
        val n = content.size
        var depth = 1
        while (i < n && depth > 0) {
            when (content[i].toInt().toChar()) {
                '[' -> {
                    depth++
                    i++
                }
                ']' -> {
                    depth--
                    i++
                }
                '(' -> {
                    val (s, next) = readLiteralString(content, i)
                    sb.append(s)
                    i = next
                }
                '<' -> {
                    if (i + 1 < n && content[i + 1] == '<'.code.toByte()) {
                        i += 2
                        continue
                    }
                    val (s, next) = readHexString(content, i)
                    sb.append(s)
                    i = next
                }
                else -> i++
            }
        }
        return sb.toString() to i
    }

    private fun indexOfToken(hay: ByteArray, from: Int, token: String): Int {
        val needle = token.toByteArray(Charsets.ISO_8859_1)
        val n = hay.size
        val m = needle.size
        outer@ for (i in from..(n - m)) {
            for (j in 0 until m) {
                if (hay[i + j] != needle[j]) continue@outer
            }
            // Word-boundary: not preceded/followed by a name char.
            val beforeOk = i == 0 || !hay[i - 1].isPdfNameChar()
            val afterOk = i + m >= n || !hay[i + m].isPdfNameChar()
            if (beforeOk && afterOk) return i
        }
        return -1
    }

    private fun ByteArray.lastIndexOf(needle: ByteArray, endExclusive: Int): Int {
        val m = needle.size
        if (m == 0 || endExclusive < m) return -1
        val last = (endExclusive - m).coerceAtMost(size - m)
        outer@ for (i in last downTo 0) {
            for (j in 0 until m) {
                if (this[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }

    private fun Byte.isPdfWhitespace(): Boolean {
        val c = toInt()
        return c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
    }

    private fun Byte.isPdfNameChar(): Boolean {
        val c = toInt().toChar()
        return c.isLetterOrDigit() || c == '_' || c == '-' || c == '+' || c == '.'
    }
}
