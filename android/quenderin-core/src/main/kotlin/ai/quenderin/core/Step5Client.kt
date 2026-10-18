package ai.quenderin.core

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.Authenticator
import java.net.CookieHandler
import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.Timer
import java.util.TimerTask

data class Step5Message(val role: String, val content: String)
data class Step5Answer(val text: String, val truncated: Boolean)

object Step5Contract {
    const val MODEL_REVISION = "364b3b03fed2477aa0953fe855a2c4c8c48ee3cc"
    const val BACKEND_REVISION = "e177c621f2b8ae1be06190bc34eef84646e54f11"
    fun endpoint(input: String): URI {
        require(input.length <= 2048 && input.toByteArray(Charsets.UTF_8).size <= 2048) { "Enter your Step 5 gateway origin." }
        val uri = URI(input)
        require(!uri.host.isNullOrEmpty() && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null
            && uri.rawPath in listOf("", "/") && (uri.port == -1 || uri.port in 1..65535)
            && (uri.scheme.equals("https", true) || (uri.scheme.equals("http", true) && uri.host in listOf("127.0.0.1", "[::1]", "::1")))) {
            "Use an HTTPS origin or http://127.0.0.1:18000. Credentials, paths and query strings are unavailable."
        }
        return uri
    }
    fun messages(messages: List<Step5Message>) {
        require(messages.size in 1..16 && messages.last().role == "user") { "Use 1–16 alternating messages ending with a user message." }
        var bytes = 0
        messages.forEachIndexed { index, message ->
            require(message.role == if (index % 2 == 0) "user" else "assistant") { "Step 5 messages must alternate user and assistant roles." }
            require(message.content.isNotBlank() && message.content.length <= 8192 && '\u0000' !in message.content) { "Each Step 5 message must contain 1–8,192 UTF-8 bytes." }
            val size = message.content.toByteArray(Charsets.UTF_8).size
            require(size <= 8192) { "Each Step 5 message must contain 1–8,192 UTF-8 bytes." }; bytes += size
        }
        require(bytes <= 32768) { "This conversation exceeds 32 KiB. Clear it explicitly to begin another conversation." }
    }
    fun handshake(data: ByteArray) {
        val item = flatObject(data, setOf("protocol", "modelRevision", "backendRevision", "artifactsVerified", "ready", "maxOutputTokens", "maxConcurrentRequests"))
        require(item["protocol"] == 1L && item["modelRevision"] == MODEL_REVISION && item["backendRevision"] == BACKEND_REVISION
            && item["artifactsVerified"] == true && item["ready"] == true && item["maxOutputTokens"] == 1024L && item["maxConcurrentRequests"] == 1L) {
            "The gateway is not ready with the pinned Step 5 backend and complete verified artifacts. Start scripts/run_step5_backend.py on your CUDA host."
        }
    }
    fun answer(data: ByteArray): Step5Answer {
        val item = flatObject(data, setOf("text", "truncated")); val text = item["text"] as? String
        require(text != null && text.isNotBlank() && '\u0000' !in text && text.toByteArray(Charsets.UTF_8).size <= 256 * 1024 && item["truncated"] is Boolean
            && !Regex("</?(?:think|tool_call)|<\\|(?:im_start|im_end|channel)|<｜", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            "The gateway did not return a complete final answer. Private reasoning and tool output cannot be displayed."
        }
        return Step5Answer(text, item["truncated"] as Boolean)
    }
    fun quote(text: String): String = buildString {
        append('"'); text.forEach { char -> when (char) {
            '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
            else -> if (char.code < 32) append("\\u%04x".format(char.code)) else append(char)
        } }; append('"')
    }
    private fun flatObject(data: ByteArray, keys: Set<String>): Map<String, Any> {
        val invalid = "The Step 5 gateway returned invalid or incomplete protocol JSON."
        require(data.size <= 300 * 1024) { invalid }
        val input = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString()
        var offset = 0
        fun space() { while (offset < input.length && input[offset] in " \t\r\n") offset++ }
        fun take(char: Char) { space(); require(offset < input.length && input[offset++] == char) { invalid } }
        fun string(): String {
            take('"'); val value = StringBuilder()
            while (offset < input.length) {
                val next = input[offset++]
                if (next == '"') return value.toString()
                require(next.code >= 32) { invalid }
                if (next != '\\') { value.append(next); continue }
                require(offset < input.length) { invalid }
                when (val escaped = input[offset++]) {
                    '"', '\\', '/' -> value.append(escaped)
                    'b' -> value.append('\b'); 'f' -> value.append('\u000c'); 'n' -> value.append('\n'); 'r' -> value.append('\r'); 't' -> value.append('\t')
                    'u' -> { require(offset + 4 <= input.length) { invalid }; val hex = input.substring(offset, offset + 4); require(hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) { invalid }; value.append(hex.toInt(16).toChar()); offset += 4 }
                    else -> error(invalid)
                }
            }; error(invalid)
        }
        val result = linkedMapOf<String, Any>()
        take('{')
        while (true) {
            val key = string(); require(key.length <= 128 && key in keys && key !in result) { invalid }; take(':'); space()
            require(offset < input.length) { invalid }
            val value: Any = if (input[offset] == '"') string() else {
                val start = offset; while (offset < input.length && input[offset] !in " \t\r\n,}") offset++
                when (val literal = input.substring(start, offset)) {
                    "true" -> true; "false" -> false
                    else -> { require(literal.length <= 20 && Regex("-?(0|[1-9][0-9]*)").matches(literal)) { invalid }; literal.toLongOrNull() ?: error(invalid) }
                }
            }
            result[key] = value; space(); if (offset >= input.length || input[offset] != ',') break; offset++
        }
        take('}'); space(); require(offset == input.length && result.keys == keys) { invalid }; return result
    }
}

interface Step5Transport {
    fun open(url: URI, body: ByteArray?, timeoutMs: Int): Step5Response
    fun cancel()
}
class Step5Response(val status: Int, val contentLength: Long, val body: InputStream, private val close: () -> Unit) : AutoCloseable {
    override fun close() { try { body.close() } finally { close.invoke() } }
}
class Step5JvmHttpTransport : Step5Transport {
    @Volatile private var current: HttpURLConnection? = null
    private val cancelled = AtomicBoolean(false)
    override fun cancel() { cancelled.set(true); current?.disconnect() }
    override fun open(url: URI, body: ByteArray?, timeoutMs: Int): Step5Response {
        if (cancelled.get()) throw CancellationException("Step 5 request cancelled.")
        // This client cannot participate in process-global cookie/authenticator stores.
        // Android has no public getDefault API. Its app injects the explicit OkHttp transport.
        val defaultAuthenticator = runCatching { Authenticator::class.java.getMethod("getDefault").invoke(null) }
            .getOrElse { error("This platform requires an explicit no-credential Step 5 transport.") }
        require(CookieHandler.getDefault() == null && defaultAuthenticator == null) { "Step 5 requires a connection without automatic cookies or credentials." }
        val connection = url.toURL().openConnection() as HttpURLConnection
        current = connection
        try {
            if (cancelled.get()) throw CancellationException("Step 5 request cancelled.")
            connection.instanceFollowRedirects = false; connection.connectTimeout = timeoutMs; connection.readTimeout = timeoutMs; connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) { connection.requestMethod = "POST"; connection.doOutput = true; connection.setRequestProperty("Content-Type", "application/json"); connection.setFixedLengthStreamingMode(body.size); connection.outputStream.use { it.write(body) } }
            val code = connection.responseCode
            if (code != 200) { connection.disconnect(); error("The Step 5 gateway returned HTTP $code.") }
            return Step5Response(code, connection.contentLengthLong, connection.inputStream) { connection.disconnect(); if (current === connection) current = null }
        } catch (failure: Exception) { connection.disconnect(); if (current === connection) current = null; throw failure }
    }
}

/** One foreground request; no retries, credentials, downloads or provisioning. */
class Step5Client(private val transportFactory: () -> Step5Transport = { Step5JvmHttpTransport() }, private val timeoutMs: Long = 180_000) {
    private class Operation(val transport: Step5Transport, val deadline: Long) { val cancelled = AtomicBoolean(false); fun cancel() { cancelled.set(true); transport.cancel() } }
    private val active = AtomicReference<Operation?>()
    init { require(timeoutMs in 1..180_000) }
    fun cancel() { active.get()?.cancel() }
    private fun checkCancelled(operation: Operation) { if (operation.cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException("Step 5 request cancelled.") }
    private fun <T> run(endpoint: String, work: (URI, Operation) -> T): T {
        val url = Step5Contract.endpoint(endpoint)
        val operation = Operation(transportFactory(), System.nanoTime() + timeoutMs * 1_000_000)
        check(active.compareAndSet(null, operation)) { "A Step 5 request is already running." }
        // An independent watchdog also interrupts a blocked connection/output write.
        val timer = Timer("quenderin-step5-deadline", true)
        timer.schedule(object : TimerTask() { override fun run() { operation.cancel() } }, timeoutMs)
        try { return work(url, operation) } finally { timer.cancel(); active.compareAndSet(operation, null) }
    }
    private fun json(url: URI, body: ByteArray?, maximum: Int, operation: Operation): ByteArray {
        checkCancelled(operation); val remaining = (operation.deadline - System.nanoTime()) / 1_000_000
        check(remaining > 0) { "The Step 5 request timed out." }
        operation.transport.open(url, body, remaining.coerceAtMost(180_000).toInt().coerceAtLeast(1)).use { response ->
            require(response.status == 200 && response.contentLength <= maximum) { "The Step 5 gateway exceeded its response limit." }
            val output = ByteArrayOutputStream(); val buffer = ByteArray(8192)
            while (true) {
                checkCancelled(operation); check(System.nanoTime() < operation.deadline) { "The Step 5 request timed out." }
                val count = response.body.read(buffer); if (count < 0) break
                require(count <= maximum - output.size()) { "The Step 5 gateway exceeded its response limit." }; output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }
    fun check(endpoint: String) = run(endpoint) { url, operation -> Step5Contract.handshake(json(url.resolve("/quenderin/step5"), null, 8192, operation)) }
    fun answer(endpoint: String, messages: List<Step5Message>): Step5Answer {
        Step5Contract.messages(messages)
        val body = ("{\"messages\":[" + messages.joinToString(",") { "{\"role\":${Step5Contract.quote(it.role)},\"content\":${Step5Contract.quote(it.content)}}" } + "]}").toByteArray(Charsets.UTF_8)
        return run(endpoint) { url, operation ->
            Step5Contract.handshake(json(url.resolve("/quenderin/step5"), null, 8192, operation))
            Step5Contract.answer(json(url.resolve("/quenderin/step5/answer"), body, 300 * 1024, operation))
        }
    }
}
