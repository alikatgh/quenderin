package ai.quenderin.core

import java.io.File

/**
 * The first real T1 capability (AGENT_AUTONOMY_PLAN Milestone 0, step 3): read a text file the
 * USER selected. The security property lives in the [grantedFiles] seam — only files the user
 * explicitly picked (document picker / attach UI) ever enter that map, so the model can NAME a
 * granted file but can never mint a path. A path in LLM output is not a grant (§7). Read-only,
 * size-capped, consent-gated by tier. Twin of iOS `FileReadCapability`.
 */
class FileReadCapability(
    /** User-granted files: display name → location. Populated ONLY by user file-picks. */
    private val grantedFiles: () -> Map<String, File>,
    /** Cap what one read pulls into the context — a T1 read must not become a context hog. */
    private val maxBytes: Int = 64 * 1024,
) : Capability {
    override val name = "fs.read"
    override val purpose = "Read a text file the user has attached, by its name. Only user-attached files are readable."
    override val tier = CapabilityTier.READ_ONLY
    override val blastRadius: BlastRadius = BlastRadius.Read("a file you selected")

    /** Exact name, then case-insensitive. Deliberately NO fuzzy matching — a T1 resource lookup
     *  must be predictable, not clever. */
    private fun resolve(requested: String): Pair<String, File>? {
        val files = grantedFiles()
        val trimmed = requested.trim()
        files[trimmed]?.let { return trimmed to it }
        return files.entries.firstOrNull { it.key.equals(trimmed, ignoreCase = true) }
            ?.let { it.key to it.value }
    }

    override fun plan(input: String): ActionPreview {
        val match = resolve(input)
            ?: return ActionPreview("Nothing to read: no attached file named \"$input\". The user must attach it first.", mutates = false)
        val (name, file) = match
        val sizeNote = if (file.isFile) " (${file.length()} bytes)" else ""
        return ActionPreview("Would read the attached file \"$name\"$sizeNote. Read-only.", mutates = false)
    }

    override fun run(input: String): String {
        val match = resolve(input) ?: run {
            val available = grantedFiles().keys.sorted().joinToString(", ")
            return if (available.isEmpty()) "No files are attached. Ask the user to attach the file first."
            else "No attached file named \"$input\". Attached files: $available."
        }
        val (name, file) = match
        if (!file.isFile) return "Couldn't open \"$name\" — it may have been moved or deleted."
        val bytes = try {
            file.inputStream().use { it.readNBytes(maxBytes + 1) }
        } catch (t: Throwable) {
            return "Couldn't read \"$name\"."
        }
        val truncated = bytes.size > maxBytes
        val slice = if (truncated) bytes.copyOf(maxBytes) else bytes
        val text = decodeUtf8Strict(slice)
            ?: return "\"$name\" isn't a text file (or isn't UTF-8) — fs.read only reads text."
        return if (truncated) text + "\n[…truncated at ${maxBytes / 1024} KB]" else text
    }

    /** Strict UTF-8: reject (null) on malformed bytes instead of silently replacing them. */
    private fun decodeUtf8Strict(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (t: Throwable) {
        null
    }
}
