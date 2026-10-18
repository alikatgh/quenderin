package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Synthetic bytes only. This verifies the app contract, never full-weight inference or UI. */
fun main() {
    val bytes = byteArrayOf(1, 2, 3, 4)
    val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    val parts = listOf("diffusion", "text_encoder", "vae").map {
        ImageModelComponent(it, "fixture/model", "a".repeat(40), "$it.bin", "$it.bin", bytes.size.toLong(), sha, "public")
    }
    val model = ImageModel("fixture-image", "Fixture", 1, "Fixture", "https://example.com/terms", false,
        ImageModelDefaults(512, 512, 1), parts)
    model.validate()
    check(ImageResourceBudget(8L * 1_073_741_824, Long.MAX_VALUE).blockReason(model, true) != null)
    check(ImageResourceBudget(Long.MAX_VALUE, model.downloadBytes).blockReason(model, true) != null)
    val root = Files.createTempDirectory("quenderin-image-fixture-").toFile().canonicalFile
    try {
        fun mustFail(action: () -> Unit) { check(runCatching(action).isFailure) }
        mustFail { ImageModelFiles.verify(model, root) }
        File(root, parts[0].localFilename).writeBytes(bytes)
        val remaining = model.downloadBytes - parts[0].bytes
        val retryBudget = ImageResourceBudget(Long.MAX_VALUE, 1_073_741_824L + remaining)
        check(retryBudget.blockReason(model, true) != null)
        check(ImageModelFiles.remainingDownloadBytes(model, root) == remaining)
        check(retryBudget.blockReason(model, true, ImageModelFiles.remainingDownloadBytes(model, root)) == null)
        parts.forEach { File(root, it.localFilename).writeBytes(bytes) }
        ImageModelFiles.verify(model, root)
        File(root, parts[1].localFilename).writeBytes(byteArrayOf(9, 9, 9, 9))
        mustFail { ImageModelFiles.verify(model, root) }
        mustFail { ImageModelFiles.remainingDownloadBytes(model, root) }
        check(File(root, parts[1].localFilename).readBytes().contentEquals(byteArrayOf(9, 9, 9, 9)))
        File(root, parts[1].localFilename).writeBytes(bytes)
        check(runCatching { ImageModelFiles.verify(model, root) { true } }.exceptionOrNull() is CancellationException)
        val linked = File(root, "linked")
        Files.createSymbolicLink(linked.toPath(), root.toPath())
        mustFail { ImageModelFiles.verify(model, linked) }
        linked.delete()
        mustFail { model.copy(components = parts.dropLast(1)).validate() }
        mustFail { model.copy(components = parts.map { it.copy(localFilename = "../escape") }).validate() }
        if (!NativeImageGenerationBridge.available) {
            val engine = NativeImageGenerationEngine { ImageResourceBudget(Long.MAX_VALUE, Long.MAX_VALUE) }
            mustFail { engine.generate(ImageGenerationRequest(model, root, "Fixture", File(root, "result.png"))) {} }
            check(!File(root, "result.png").exists())
        }
        println("PASS: image component checksum, completeness, cancellation, symlink, resource and unavailable-engine fixtures")
    } finally { root.listFiles()?.forEach { it.delete() }; root.delete() }
}
