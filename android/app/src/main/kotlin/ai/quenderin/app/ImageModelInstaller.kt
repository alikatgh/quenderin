package ai.quenderin.app

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import ai.quenderin.core.ImageModel
import ai.quenderin.core.ImageModelComponent
import ai.quenderin.core.ImageModelDefaults
import ai.quenderin.core.ImageModelFiles
import ai.quenderin.core.ImageResourceBudget
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.net.URL
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

object ImageModelJSON {
    fun decode(bytes: ByteArray): List<ImageModel> {
        require(bytes.size <= 1_048_576) { "Image catalog is too large" }
        val root = JSONObject(bytes.toString(Charsets.UTF_8))
        require(root.getInt("version") == 1) { "Unsupported image catalog" }
        val models = root.getJSONArray("models")
        require(models.length() in 1..8) { "Invalid image catalog" }
        val result = (0 until models.length()).map { index ->
            val row = models.getJSONObject(index)
            val defaults = row.getJSONObject("defaults")
            val components = row.getJSONArray("components")
            ImageModel(row.getString("id"), row.getString("label"), row.getInt("modelKind"),
                row.getString("license"), row.getString("licenseUrl"), row.getBoolean("requiresPublisherAccess"),
                ImageModelDefaults(defaults.getInt("width"), defaults.getInt("height"), defaults.getInt("steps")),
                (0 until components.length()).map { partIndex ->
                    val part = components.getJSONObject(partIndex)
                    ImageModelComponent(part.getString("role"), part.getString("repo"), part.getString("revision"),
                        part.getString("filename"), part.getString("localFilename"), part.getLong("bytes"),
                        part.getString("sha256"), part.getString("access"))
                }).also { it.validate() }
        }
        require(result.map { it.id }.distinct().size == result.size) { "Duplicate image model" }
        return result
    }
}

/** Foreground-only, one component at a time. Copies imports; never moves their originals. */
class ImageModelInstaller(context: Context) {
    private val context = context.applicationContext
    val directory = File(this.context.filesDir, "image-models").canonicalFile
    private val cancelled = AtomicBoolean(false)
    @Volatile private var connection: HttpsURLConnection? = null

    fun cancel() { cancelled.set(true); connection?.disconnect() }
    fun prepare() { cancelled.set(false) }

    fun install(model: ImageModel, budget: ImageResourceBudget, imported: List<Uri> = emptyList(),
                publisherTermsAccepted: Boolean = false, progress: (Float) -> Unit): File {
        model.validate()
        budget.blockReason(model, installing = false)?.let { error(it) }
        require(!model.requiresPublisherAccess || (publisherTermsAccepted && imported.isNotEmpty())) {
            "Review the publisher terms, then import the files obtained with your publisher access."
        }
        val folder = File(directory, model.id)
        val remaining = ImageModelFiles.remainingDownloadBytes(model, folder) { cancelled.get() }
        budget.blockReason(model, installing = true, remainingDownloadBytes = remaining)?.let { error(it) }
        check(folder.mkdirs() || folder.isDirectory) { "Could not create image model folder" }
        require(folder.canonicalFile == folder.absoluteFile) { "Image model folder must not contain symbolic links" }
        val sources = imported.map { it to displayName(it) }
        var completed = 0L
        for (part in model.components) {
            checkCancelled()
            val final = File(folder, part.localFilename)
            if (final.exists()) {
                ImageModelFiles.verifyComponent(part, final) { cancelled.get() }
            } else {
                val staging = File(folder, ".${UUID.randomUUID()}.partial")
                check(staging.createNewFile()) { "Could not create component staging file" }
                try {
                    if (sources.isNotEmpty()) {
                        val matches = sources.filter { (_, name) -> name == part.localFilename || name == part.filename.substringAfterLast('/') }
                        require(matches.size == 1) { "Choose exactly one file for ${part.localFilename}, including every model component." }
                        val stream = context.contentResolver.openInputStream(matches.single().first)
                            ?: error("Could not open ${part.localFilename}")
                        stream.use { copyVerified(it, staging, part) { count -> progress((completed + count).toFloat() / model.downloadBytes) } }
                    } else {
                        require(part.access == "public") { "This component requires publisher access; import it after reviewing the publisher terms." }
                        val request = open(part.downloadUrl)
                        connection = request
                        try {
                            require(request.contentLengthLong < 0 || request.contentLengthLong == part.bytes) { "Server returned an unexpected component size" }
                            request.inputStream.use { copyVerified(it, staging, part) { count -> progress((completed + count).toFloat() / model.downloadBytes) } }
                        } finally { request.disconnect(); connection = null }
                    }
                    checkCancelled()
                    // Without REPLACE_EXISTING: a concurrent installation cannot erase a file.
                    Files.move(staging.toPath(), final.toPath())
                } finally { if (staging.exists()) staging.delete() }
            }
            completed += part.bytes
            progress(completed.toFloat() / model.downloadBytes)
        }
        return folder
    }

    private fun copyVerified(input: InputStream, output: File, part: ImageModelComponent, progress: (Long) -> Unit) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1 shl 16)
        val deadline = System.nanoTime() + 7_200_000_000_000L
        var count = 0L
        var reported = 0L
        output.outputStream().use { target ->
            while (true) {
                checkCancelled()
                check(System.nanoTime() < deadline) { "Image component transfer timed out" }
                val read = input.read(buffer)
                if (read < 0) break
                count += read
                require(count <= part.bytes) { "Image component exceeds its pinned size" }
                target.write(buffer, 0, read); digest.update(buffer, 0, read)
                if (count - reported >= 8L * 1024 * 1024) { reported = count; progress(count) }
            }
        }
        checkCancelled()
        val sha = digest.digest().joinToString("") { "%02x".format(it) }
        require(count == part.bytes && sha == part.sha256) { "Image component failed its exact size or checksum check" }
    }

    private fun open(address: String): HttpsURLConnection {
        var next = URL(address)
        repeat(9) {
            checkCancelled()
            require(next.protocol == "https") { "Image downloads require HTTPS" }
            val request = next.openConnection() as HttpsURLConnection
            connection = request
            request.connectTimeout = 30_000; request.readTimeout = 30_000
            request.instanceFollowRedirects = false
            request.setRequestProperty("Cookie", "")
            try {
                when (request.responseCode) {
                    200 -> return request
                    301, 302, 303, 307, 308 -> {
                        val location = request.getHeaderField("Location") ?: error("Invalid component redirect")
                        next = URL(next, location); request.disconnect()
                    }
                    else -> { val code = request.responseCode; request.disconnect(); error("Image download returned HTTP $code") }
                }
            } catch (error: Exception) {
                request.disconnect(); connection = null
                if (cancelled.get()) throw CancellationException("Image installation cancelled")
                throw error
            }
        }
        error("Too many image component redirects")
    }
    private fun displayName(uri: Uri): String = context.contentResolver.query(uri,
        arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: uri.lastPathSegment.orEmpty()
    private fun checkCancelled() { if (cancelled.get()) throw CancellationException("Image installation cancelled") }
}
