package ai.quenderin.core

import java.io.File

/**
 * Turns a user-picked file into an [AttachedDocument] at attach time (Milestone 1 — documents in
 * chat). Text files only for now: strict UTF-8 (a binary file is refused with a reason, never
 * silently mangled), capped so one attachment can't blow the model's context. Twin of iOS
 * `DocumentTextExtractor`; the Compose attach UI plugs in here when it lands.
 */
object DocumentTextExtractor {
    sealed interface Extraction {
        data class Document(val document: AttachedDocument) : Extraction
        data class Rejected(val reason: String) : Extraction
    }

    /** 24 KB default: enough for READMEs/configs/notes, small enough that a 2048-token context
     *  (a phone under pressure) still has room to answer about it. */
    @JvmOverloads
    fun extract(name: String, file: File, maxBytes: Int = 24 * 1024): Extraction {
        if (!file.isFile) return Extraction.Rejected("Couldn't open \"$name\".")
        val bytes = try {
            file.inputStream().use { it.readNBytes(maxBytes + 1) }
        } catch (t: Throwable) {
            return Extraction.Rejected("Couldn't read \"$name\".")
        }
        val truncated = bytes.size > maxBytes
        val slice = if (truncated) bytes.copyOf(maxBytes) else bytes
        val text = try {
            Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(slice)).toString()
        } catch (t: Throwable) {
            return Extraction.Rejected("\"$name\" isn't a text file — only text attachments are supported for now.")
        }
        val body = if (truncated) text + "\n[…file truncated at ${maxBytes / 1024} KB]" else text
        return Extraction.Document(AttachedDocument(name, body))
    }
}
