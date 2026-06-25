package ai.quenderin.core

import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI

/**
 * Real [HttpRangeClient] / [FileSink] on plain JVM APIs (`HttpURLConnection`, `RandomAccessFile`)
 * — no Android dependency, so [ModelDownloadEngine] can do an actual resumable transfer that
 * compiles under `kotlinc` and runs on the JVM. The Android `:app` `WorkManager` worker
 * constructs these with the app's `filesDir`; nothing here needs the SDK.
 */

/** HTTP client that issues a `Range:` request to resume, and streams the body in chunks. */
class JvmHttpRangeClient(
    private val chunkSize: Int = 1 shl 16, // 64 KiB
    private val connectTimeoutMs: Int = 30_000,
    private val readTimeoutMs: Int = 60_000,
) : HttpRangeClient {

    override fun open(url: String, offsetBytes: Long): RangeResponse {
        // Enforce the TLS contract ModelIntegrity documents: a multi-GB model must only ever be
        // fetched over HTTPS. Reject http:// / file:// / anything else BEFORE opening a connection,
        // so a stray catalog/resume URL can't stream weights in cleartext over an attacker-modifiable
        // channel (the optional SHA-256 is the only other line of defense). The choke point for every
        // transfer — fresh, resumed, and restored-from-disk — passes through here.
        val scheme = URI(url).scheme
        if (!"https".equals(scheme, ignoreCase = true)) {
            throw DownloadException("refusing non-HTTPS model URL (scheme=$scheme): $url")
        }
        val conn = (URI(url).toURL().openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = true
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
            requestMethod = "GET"
            if (offsetBytes > 0) setRequestProperty("Range", "bytes=$offsetBytes-")
        }

        val code = conn.responseCode
        if (code != HttpURLConnection.HTTP_OK && code != HttpURLConnection.HTTP_PARTIAL) {
            conn.disconnect()
            throw DownloadException("HTTP $code for $url")
        }

        val resumed = code == HttpURLConnection.HTTP_PARTIAL
        val total = totalBytes(conn, resumed, offsetBytes)
        val stream = conn.inputStream
        val body = sequence {
            val buffer = ByteArray(chunkSize)
            try {
                while (true) {
                    val n = stream.read(buffer)
                    if (n < 0) break
                    if (n > 0) yield(buffer.copyOf(n))
                }
            } finally {
                stream.close()
                conn.disconnect()
            }
        }
        return RangeResponse(totalBytes = total, resumed = resumed, body = body)
    }

    /** 206 → full size is after the `/` in `Content-Range`; 200 → `Content-Length` is the full size. */
    private fun totalBytes(conn: HttpURLConnection, resumed: Boolean, offset: Long): Long {
        if (resumed) {
            val contentRange = conn.getHeaderField("Content-Range")
            val slash = contentRange?.lastIndexOf('/') ?: -1
            if (contentRange != null && slash >= 0) {
                contentRange.substring(slash + 1).trim().toLongOrNull()?.let { return it }
            }
            val len = conn.getHeaderFieldLong("Content-Length", -1)
            return if (len >= 0) offset + len else -1
        }
        return conn.getHeaderFieldLong("Content-Length", -1)
    }
}

/** Append-only file sink that resumes a `.part` file and finalizes with an atomic rename. */
class JvmFileSink : FileSink {

    override fun existingSize(path: String): Long =
        File(path).let { if (it.isFile) it.length() else 0L }

    override fun truncate(path: String) {
        File(path).delete()
    }

    override fun append(path: String, bytes: ByteArray) {
        val file = File(path)
        file.parentFile?.mkdirs()
        RandomAccessFile(file, "rw").use { raf ->
            raf.seek(raf.length())
            raf.write(bytes)
        }
    }

    override fun head(path: String, n: Int): ByteArray {
        val file = File(path)
        if (!file.isFile) return ByteArray(0)
        RandomAccessFile(file, "r").use { raf ->
            val len = minOf(n.toLong(), raf.length()).toInt()
            val buf = ByteArray(len)
            raf.readFully(buf)
            return buf
        }
    }

    // Streamed in constant memory via the shared ModelIntegrity helper (the canonical impl).
    override fun sha256(path: String): String = ModelIntegrity.sha256Hex(File(path))

    override fun finalize(tempPath: String, finalPath: String) {
        val temp = File(tempPath)
        val dest = File(finalPath)
        dest.parentFile?.mkdirs()
        if (dest.exists()) dest.delete()
        if (!temp.renameTo(dest)) {
            // Cross-filesystem fallback (e.g. internal storage → SD card). If the copy fails
            // midway, delete the partial dest so no half-written file is left behind a passed
            // integrity gate (C3-4).
            try {
                temp.copyTo(dest, overwrite = true)
                temp.delete()
            } catch (e: Exception) {
                runCatching { dest.delete() }
                throw e
            }
        }
    }
}
