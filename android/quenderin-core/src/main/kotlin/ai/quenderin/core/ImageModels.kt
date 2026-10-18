package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest

data class ImageModelComponent(
    val role: String, val repo: String, val revision: String, val filename: String,
    val localFilename: String, val bytes: Long, val sha256: String, val access: String,
) {
    val downloadUrl: String get() = "https://huggingface.co/$repo/resolve/$revision/$filename?download=true"
}

data class ImageModelDefaults(val width: Int, val height: Int, val steps: Int)

data class ImageModel(
    val id: String, val label: String, val modelKind: Int, val license: String,
    val licenseUrl: String, val requiresPublisherAccess: Boolean,
    val defaults: ImageModelDefaults, val components: List<ImageModelComponent>,
) {
    val downloadBytes: Long get() = components.sumOf { it.bytes }

    fun validate() {
        val safeName = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$")
        require(safeName.matches(id) && !id.contains("..") && modelKind in 1..3) { "Invalid image model identity" }
        val roles = if (modelKind == 1) setOf("diffusion", "text_encoder", "vae")
            else setOf("diffusion", "text_encoder", "vae", "tokenizer")
        require(components.size == roles.size && components.map { it.role }.toSet() == roles &&
            components.map { it.localFilename }.distinct().size == components.size) { "Incomplete image model manifest" }
        require(defaults.width == 512 && defaults.height == 512 && defaults.steps in 1..50) { "Invalid image model defaults" }
        require(licenseUrl.startsWith("https://")) { "Invalid license URL" }
        components.forEach { part ->
            require(safeName.matches(part.localFilename) && !part.localFilename.contains("..") &&
                Regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$").matches(part.repo) &&
                Regex("^[a-f0-9]{40}$").matches(part.revision) && Regex("^[a-f0-9]{64}$").matches(part.sha256) &&
                part.bytes in 1 until 100_000_000_000L && part.filename.isNotEmpty() &&
                part.filename.split('/').all { safeName.matches(it) && !it.contains("..") } &&
                part.access in setOf("public", "publisher-gated")) { "Invalid image model component provenance" }
        }
    }
}

data class ImageResourceBudget(val availableMemoryBytes: Long, val freeDiskBytes: Long) {
    fun blockReason(model: ImageModel, installing: Boolean, remainingDownloadBytes: Long? = null): String? = when {
        availableMemoryBytes < REQUIRED_MEMORY_BYTES ->
            "This experimental model needs at least 24 GiB of available app memory. Choose a larger device or close other apps."
        remainingDownloadBytes != null && remainingDownloadBytes !in 0L..model.downloadBytes -> "The remaining image model size is invalid."
        freeDiskBytes < (if (installing) remainingDownloadBytes ?: model.downloadBytes else 0L) + 1_073_741_824L ->
            "There is not enough free space for the remaining model components and image output."
        else -> null
    }
    companion object { const val REQUIRED_MEMORY_BYTES = 24L * 1_073_741_824L }
}

object ImageModelFiles {
    /** Existing files reduce disk reservation only after their full pinned hash matches. */
    fun remainingDownloadBytes(model: ImageModel, directory: File, cancelled: () -> Boolean = { false }): Long {
        model.validate()
        require(directory.canonicalFile == directory.absoluteFile) { "Image model directory must not contain links" }
        var remaining = 0L
        model.components.forEach { component ->
            if (cancelled()) throw java.util.concurrent.CancellationException("Image verification cancelled")
            val file = File(directory, component.localFilename)
            if (Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) verifyComponent(component, file, cancelled)
            else remaining += component.bytes
        }
        return remaining
    }

    /** No filename/size-only readiness claim: every required component is hashed before inference. */
    fun verify(model: ImageModel, directory: File, cancelled: () -> Boolean = { false }) {
        model.validate()
        require(directory.canonicalFile == directory.absoluteFile) { "Image model directory must not contain links" }
        model.components.forEach { component ->
            verifyComponent(component, File(directory, component.localFilename), cancelled)
        }
    }

    fun verifyComponent(component: ImageModelComponent, file: File, cancelled: () -> Boolean = { false }) {
            require(file.canonicalFile == file.absoluteFile && file.isFile && file.length() == component.bytes) {
                "Missing or incomplete ${component.localFilename}"
            }
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    if (cancelled()) throw java.util.concurrent.CancellationException("Image verification cancelled")
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            require(hash == component.sha256 && file.length() == component.bytes) { "Checksum failed for ${component.localFilename}" }
    }
}
