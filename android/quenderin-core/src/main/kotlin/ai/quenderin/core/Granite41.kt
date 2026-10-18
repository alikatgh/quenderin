package ai.quenderin.core

import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.CancellationException

data class GraniteMessage(val role: Role, val content: String) { enum class Role { USER, ASSISTANT } }
object Granite41 {
    const val SOURCE_REVISION = "0d1625d16df2d54cafb6bc5cb0650aec043f77d6"
    const val CONVERTER_SHA256 = "301fbf51eb833e8481b4f516b28a23cd374f25db88c3e6e8af8277ecad826248"
    const val MINIMUM_MEMORY_BYTES = 34_359_738_368L
    const val MAXIMUM_MODEL_BYTES = 34_359_738_368L
    fun requiredMemory(bytes: Long): Long = maxOf(MINIMUM_MEMORY_BYTES, (bytes * 13 + 9) / 10 + 536_870_912L)
    fun prompt(messages: List<GraniteMessage>): String {
        require(messages.isNotEmpty() && messages.size <= 32 && messages.size % 2 == 1) { "Use a bounded conversation ending in a user question." }
        val result = buildString {
            messages.forEachIndexed { index, message ->
                require(message.role == (if (index % 2 == 0) GraniteMessage.Role.USER else GraniteMessage.Role.ASSISTANT)
                    && message.content.isNotEmpty() && message.content.toByteArray(Charsets.UTF_8).size <= 65_536 && '\u0000' !in message.content) { "Invalid Granite conversation." }
                append("<|start_of_role|>").append(if (message.role == GraniteMessage.Role.USER) "user" else "assistant")
                append("<|end_of_role|>").append(message.content.replace("<|", "< |")).append("<|end_of_text|>\n")
            }
            append("<|start_of_role|>assistant<|end_of_role|>")
        }
        require(result.toByteArray(Charsets.UTF_8).size <= 32_768) { "This conversation is full. Start a new Granite conversation." }
        return result
    }
    fun finalAnswer(output: String): String {
        val answer = output.substringBefore("<|").trim()
        require(answer.isNotEmpty() && answer.toByteArray(Charsets.UTF_8).size <= 65_536 && !Regex("</?think|<tool_call", RegexOption.IGNORE_CASE).containsMatchIn(answer)) { "Granite did not return a final text answer." }
        return answer
    }
}

/** Bounded JSON reader rejects duplicate keys, nonfinite numbers and malformed strings. */
private class GraniteJson(private val source: String) {
    private var cursor = 0; private var nodes = 0
    private fun space() { while (cursor < source.length && source[cursor] in " \t\r\n") cursor++ }
    private fun take(ch: Char) { space(); require(cursor < source.length && source[cursor++] == ch) { "Invalid conversion JSON." } }
    private fun string(): String {
        take('"'); val result = StringBuilder()
        while (cursor < source.length) {
            val ch = source[cursor++]
            if (ch == '"') {
                val value = result.toString(); require(value.length <= 16_384 && '\u0000' !in value && Charsets.UTF_8.newEncoder().canEncode(value)); return value
            }
            require(ch >= ' ') { "Control character in conversion JSON." }
            if (ch != '\\') result.append(ch)
            else {
                require(cursor < source.length); val escaped = source[cursor++]
                result.append(when (escaped) {
                    '"', '\\', '/' -> escaped; 'b' -> '\b'; 'f' -> '\u000c'; 'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'
                    'u' -> { require(cursor + 4 <= source.length); val hex = source.substring(cursor, cursor + 4); require(hex.all { it in "0123456789abcdefABCDEF" }); cursor += 4; hex.toInt(16).toChar() }
                    else -> error("Invalid conversion JSON escape.")
                })
            }
            require(result.length <= 16_384)
        }
        error("Incomplete conversion JSON string.")
    }
    private fun value(depth: Int): Any? {
        require(depth <= 24 && ++nodes <= 4096); space(); require(cursor < source.length)
        return when (source[cursor]) {
            '{' -> {
                take('{'); val map = linkedMapOf<String, Any?>(); space()
                if (source.getOrNull(cursor) != '}') while (true) {
                    val key = string(); require(!map.containsKey(key)) { "Duplicate conversion JSON key." }; take(':'); map[key] = value(depth + 1); space()
                    if (source.getOrNull(cursor) != ',') break; cursor++
                }
                take('}'); map
            }
            '[' -> {
                take('['); val array = mutableListOf<Any?>(); space()
                if (source.getOrNull(cursor) != ']') while (true) { array.add(value(depth + 1)); space(); if (source.getOrNull(cursor) != ',') break; cursor++ }
                take(']'); array
            }
            '"' -> string()
            't' -> { require(source.startsWith("true", cursor)); cursor += 4; true }
            'f' -> { require(source.startsWith("false", cursor)); cursor += 5; false }
            'n' -> { require(source.startsWith("null", cursor)); cursor += 4; null }
            else -> {
                val start = cursor
                while (cursor < source.length && source[cursor] in "-+0123456789.eE") cursor++
                val number = source.substring(start, cursor)
                require(Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?").matches(number))
                if ('.' !in number && 'e' !in number && 'E' !in number) number.toLong()
                else number.toDouble().also { require(it.isFinite()) }
            }
        }
    }
    fun read(): Map<*, *> { val result = value(0); space(); require(cursor == source.length && result is Map<*, *>); return result }
}
internal data class GraniteConversionRecord(val bytes: Long, val sha256: String, val outtype: String) {
    companion object {
        fun parse(data: ByteArray): GraniteConversionRecord {
            require(data.size in 2..65_536) { "The conversion record must be at most 64 KiB." }
            val text = Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(data)).toString()
            val receipt = GraniteJson(text).read(); val source = receipt["source"] as? Map<*, *>; val runtime = receipt["runtime"] as? Map<*, *>
            val bytes = receipt["bytes"] as? Long; val hash = receipt["sha256"] as? String; val outtype = receipt["outtype"] as? String
            require(receipt["version"] == 1L && source?.get("repository") == "ibm-granite/granite-switch-4.1-8b"
                && source["revision"] == Granite41.SOURCE_REVISION && source["weightLayers"] == 40L
                && runtime?.get("repository") == "https://github.com/PrismML-Eng/llama.cpp.git" && runtime["revision"] == "e8fd209c975c80aa7fb36a8423571ff3b1b7e955"
                && runtime["graniteConverterPatchId"] == "granite41-official-converter-v1" && runtime["graniteConverterPatchSha256"] == Granite41.CONVERTER_SHA256
                && bytes != null && bytes in 1024..Granite41.MAXIMUM_MODEL_BYTES && hash != null && Regex("[0-9a-f]{64}").matches(hash)
                && outtype in listOf("f16", "bf16", "q8_0")) { "Choose the exact Granite Switch 4.1 8B conversion and record from scripts/convert_granite41.py." }
            return GraniteConversionRecord(bytes, hash, outtype!!)
        }
    }
}
class GraniteArtifactProof private constructor(val filePath: String, val bytes: Long, val sha256: String, private val identity: Map<String, Any>) {
    fun assertCurrent() { require(identity == identity(File(filePath))) { "The verified Granite file changed. Import or verify it again." } }
    companion object {
        internal fun identity(file: File): Map<String, Any> {
            require(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) { "Granite must be a regular local file." }
            return Files.readAttributes(file.toPath(), "unix:dev,ino,size,lastModifiedTime,ctime", LinkOption.NOFOLLOW_LINKS)
        }
        fun verify(file: File, cancelled: () -> Boolean = { false }): GraniteArtifactProof {
            fun checkCancelled() { if (cancelled() || Thread.currentThread().isInterrupted) throw CancellationException("Granite verification cancelled.") }
            checkCancelled(); val receipt = File(file.path + ".quenderin.json"); val recordIdentity = identity(receipt)
            require(receipt.length() in 2..65_536) { "Missing or excessive adjacent conversion record." }
            val data = receipt.inputStream().use { input ->
                val buffer = ByteArray(65_537); var count = 0
                while (count < buffer.size) { val read = input.read(buffer, count, buffer.size - count); if (read < 0) break; count += read }
                require(count <= 65_536); buffer.copyOf(count)
            }
            require(recordIdentity == identity(receipt)) { "The conversion record changed." }
            val record = GraniteConversionRecord.parse(data); val before = identity(file)
            require(file.length() == record.bytes && ModelIntegrity.sha256Hex(file, cancelled) == record.sha256) { "The complete converted GGUF is missing or changed." }
            require(ModelRuntimeSupport.graniteMetadataMatches(file.path) && before == identity(file)) { "The converted model must be actual Granite Switch 4.1 8B: 40 layers, 4096 embedding, one complete GGUF." }
            checkCancelled(); return GraniteArtifactProof(file.path, record.bytes, record.sha256, before)
        }
    }
}
object GraniteModelImporter {
    fun importPair(modelName: String, receiptName: String, model: InputStream, receipt: ByteArray, directory: File,
                   progress: (Float) -> Unit = {}, cancelled: () -> Boolean = { false }): GraniteArtifactProof {
        require(modelName.endsWith(".gguf", true) && receiptName == modelName + ".quenderin.json" && '/' !in modelName && '\\' !in modelName) { "Choose a GGUF and its matching GGUF.quenderin.json record together." }
        val record = GraniteConversionRecord.parse(receipt)
        check(directory.mkdirs() || directory.isDirectory); require(directory.canonicalFile == directory.absoluteFile)
        var finalFolder = File(directory, record.sha256)
        fun existing(finalFolder: File): GraniteArtifactProof {
            val finalOutput = File(finalFolder, "granite-switch-4.1-8b.gguf")
            require(finalFolder.canonicalFile == finalFolder.absoluteFile) { "The existing private import resolves through a symlink." }
            val proof = GraniteArtifactProof.verify(finalOutput, cancelled)
            require(proof.sha256 == record.sha256 && proof.bytes == record.bytes) { "The existing private import differs from the selected conversion." }
            progress(1f); return proof
        }
        val candidates = directory.listFiles()?.filter { it.name == record.sha256 || (it.name.startsWith(record.sha256 + "-") && runCatching { UUID.fromString(it.name.drop(65)) }.isSuccess) }.orEmpty()
        require(candidates.size <= 16) { "Too many retained attempts for this conversion. Choose an existing complete import." }
        for (candidate in candidates) {
            try { return existing(candidate) } catch (error: CancellationException) { throw error } catch (_: Exception) { }
        }
        if (Files.exists(finalFolder.toPath(), LinkOption.NOFOLLOW_LINKS)) finalFolder = File(directory, record.sha256 + "-" + UUID.randomUUID())
        require(directory.usableSpace >= record.bytes + 67_108_864L) { "Insufficient private storage for the complete Granite conversion." }
        val folder = File(directory, ".partial-" + UUID.randomUUID().toString()); Files.createDirectory(folder.toPath())
        val output = File(folder, "granite-switch-4.1-8b.gguf")
        try {
            Files.newByteChannel(output.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS).use { target ->
                val buffer = ByteArray(1_048_576); var count = 0L
                while (true) {
                    if (cancelled() || Thread.currentThread().isInterrupted) throw CancellationException("Granite import cancelled.")
                    val read = model.read(buffer); if (read < 0) break
                    count += read; require(count <= record.bytes) { "Selected GGUF exceeds its conversion record." }
                    val chunk = ByteBuffer.wrap(buffer, 0, read); while (chunk.hasRemaining()) check(target.write(chunk) > 0)
                    progress(minOf(0.99f, count.toFloat() / record.bytes))
                }
                require(count == record.bytes) { "The complete converted GGUF is missing." }
            }
            Files.write(File(output.path + ".quenderin.json").toPath(), receipt, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
            GraniteArtifactProof.verify(output, cancelled)
            try { Files.createDirectory(finalFolder.toPath()) }
            catch (error: java.nio.file.FileAlreadyExistsException) {
                try { return existing(finalFolder) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { }
                finalFolder = File(directory, record.sha256 + "-" + UUID.randomUUID()); Files.createDirectory(finalFolder.toPath())
            }
            val finalOutput = File(finalFolder, "granite-switch-4.1-8b.gguf")
            var published = false
            try {
                Files.createLink(finalOutput.toPath(), output.toPath())
                Files.createLink(File(finalOutput.path + ".quenderin.json").toPath(), File(output.path + ".quenderin.json").toPath())
                // Seal identity after unlinking staging names, which changes inode ctime.
                Files.delete(output.toPath()); Files.delete(File(output.path + ".quenderin.json").toPath())
                val proof = GraniteArtifactProof.verify(finalOutput, cancelled); published = true; progress(1f); return proof
            } finally { if (!published) { finalOutput.delete(); File(finalOutput.path + ".quenderin.json").delete(); finalFolder.delete() } }
        } finally { output.delete(); File(output.path + ".quenderin.json").delete(); folder.delete() }
    }
}
