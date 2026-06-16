package ai.quenderin.core

import java.io.File
import java.security.MessageDigest

/**
 * Post-download integrity verification for GGUF model files (audit finding C3).
 *
 * The download engine streams multi-GB files from catalog-pinned HTTPS URLs to disk, then
 * hands them to llama.cpp's GGUF parser (via JNI). A TLS-MITM, a poisoned mirror, or a
 * silently-truncated transfer could substitute or corrupt those bytes. This is the gate
 * between "downloaded" and "loaded": the GGUF magic header is always checked, and when the
 * catalog pins a SHA-256 the whole-file digest must match it. Twin of desktop
 * `modelIntegrity.ts` and iOS `ModelIntegrity`.
 */
object ModelIntegrity {
    /** GGUF files begin with the 4-byte magic "GGUF" (0x47 0x47 0x55 0x46). */
    val GGUF_MAGIC = byteArrayOf(0x47, 0x47, 0x55, 0x46)

    /** True iff the buffer's first 4 bytes are the GGUF magic header. */
    fun hasGGUFMagic(head: ByteArray): Boolean =
        head.size >= 4 &&
            head[0] == GGUF_MAGIC[0] && head[1] == GGUF_MAGIC[1] &&
            head[2] == GGUF_MAGIC[2] && head[3] == GGUF_MAGIC[3]

    /** Streaming lowercase-hex SHA-256 of [file] (constant memory) — the production path for
     *  model files; twin of desktop `sha256File` and iOS `sha256Hex(of:)`. */
    fun sha256Hex(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** In-memory lowercase-hex SHA-256 of [bytes] — for SMALL buffers and tests ONLY. A multi-GB
     *  model must go through [sha256Hex] (File) so the whole file never sits in the heap. */
    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

/** Thrown when a downloaded model fails its integrity check (bad magic or checksum mismatch). */
class ModelIntegrityException(message: String) : Exception(message)
