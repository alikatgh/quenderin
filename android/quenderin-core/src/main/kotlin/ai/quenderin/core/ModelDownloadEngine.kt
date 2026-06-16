package ai.quenderin.core

/**
 * The resumable-download *brain*, in pure Kotlin so it unit-tests on the JVM with no
 * Android, no Gradle, and no network. It is the portable twin of the bookkeeping side
 * of iOS `BackgroundModelDownloader` (which wires `URLSession` to `DownloadStore`); here
 * the transfer logic itself is pure and the OS-specific bits (sockets, files, WorkManager,
 * a foreground notification) are pushed behind the [HttpRangeClient] / [FileSink] seams.
 *
 * The Android `:app` layer builds this with [JvmHttpRangeClient] + [JvmFileSink] inside a
 * `WorkManager` `CoroutineWorker` so the download survives the app being backgrounded —
 * that worker is the only part that needs the Android SDK. See `android/INTEGRATION.md`.
 */

/** A range-aware HTTP response: the full size, whether the server honored the resume, and the body. */
class RangeResponse(
    /** Full size of the resource in bytes, or -1 if the server didn't say. */
    val totalBytes: Long,
    /** True when the server returned 206 and we should append after the existing bytes. */
    val resumed: Boolean,
    /** The body as a lazy sequence of byte chunks (so large files never sit in memory). */
    val body: Sequence<ByteArray>,
)

/** Opens an HTTP GET that asks to resume from [offsetBytes] (an HTTP `Range:` request). */
interface HttpRangeClient {
    fun open(url: String, offsetBytes: Long): RangeResponse
}

/** Append-only file seam — lets the engine resume a half-written file and finalize atomically. */
interface FileSink {
    /** Bytes already on disk for a partial download, or 0 if none. */
    fun existingSize(path: String): Long
    /** Discard a partial file (server can't resume, or a failed integrity check). */
    fun truncate(path: String)
    /** Append [bytes] to [path], creating it if needed. */
    fun append(path: String, bytes: ByteArray)
    /** First [n] bytes of [path] for a magic-number check; fewer if the file is shorter. */
    fun head(path: String, n: Int): ByteArray
    /** Lowercase-hex SHA-256 of the file at [path], streamed in constant memory. */
    fun sha256(path: String): String
    /** Atomically move the finished temp file into its final location. */
    fun finalize(tempPath: String, finalPath: String)
}

/** Thrown when a download cannot complete; carries a clear, surfaceable reason. */
class DownloadException(message: String) : Exception(message)

/**
 * Resumable model downloader. Implements the same [ModelDownloader] seam the mock and the
 * onboarding flow use, so it drops straight into [OnboardingModel] — but unlike the mock it
 * does a real, resumable, progress-reporting transfer (over injected seams) and mirrors
 * progress into [store] so it survives a relaunch.
 */
class ModelDownloadEngine(
    private val http: HttpRangeClient,
    private val sink: FileSink,
    private val store: DownloadStore,
    private val destinationDir: String,
    /** Report progress at most once per this fraction, to avoid flooding the UI (mirrors iOS' 1%). */
    private val progressStep: Double = 0.01,
) : ModelDownloader {

    override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String {
        val finalPath = "$destinationDir/${model.filename}"
        val tempPath = "$finalPath.part"
        var existing = sink.existingSize(tempPath)

        store.upsert(
            PersistedDownload(
                modelId = model.id,
                fileName = model.filename,
                urlString = model.url,
                destinationPath = finalPath,
                bytesDownloaded = existing,
                totalBytes = 0,
                state = PersistedDownload.State.RUNNING,
            )
        )

        try {
            val response = http.open(model.url, existing)

            // Server couldn't resume (200 not 206) but we had a partial → start over.
            if (!response.resumed && existing > 0) {
                sink.truncate(tempPath)
                existing = 0
            }

            val total = response.totalBytes            // full size (may be -1 when unknown)
            var downloaded = existing
            var lastReported = if (total > 0) (downloaded.toDouble() / total).coerceIn(0.0, 1.0) else 0.0

            for (chunk in response.body) {
                if (chunk.isEmpty()) continue
                sink.append(tempPath, chunk)
                downloaded += chunk.size
                if (total > 0) {
                    val fraction = (downloaded.toDouble() / total).coerceAtMost(1.0)
                    if (fraction - lastReported >= progressStep) {
                        lastReported = fraction
                        onProgress(fraction)
                        store.updateProgress(model.id, bytesDownloaded = downloaded, totalBytes = total)
                    }
                }
            }

            if (total > 0 && downloaded < total) {
                throw DownloadException(
                    "incomplete download for ${model.filename}: got $downloaded of $total bytes"
                )
            }

            // Integrity gate (C3): verify the assembled bytes BEFORE promoting .part → final,
            // so a MITM / poisoned-mirror / truncated file never becomes the active model. A
            // failed check discards the partial (it must not be resumed) and fails the download.
            if (!ModelIntegrity.hasGGUFMagic(sink.head(tempPath, 4))) {
                sink.truncate(tempPath)
                throw DownloadException("downloaded file for ${model.filename} is not a valid GGUF (bad magic header)")
            }
            val expectedSha = model.sha256
            if (expectedSha != null) {
                val actualSha = sink.sha256(tempPath)
                if (!actualSha.equals(expectedSha, ignoreCase = true)) {
                    sink.truncate(tempPath)
                    throw DownloadException(
                        "checksum mismatch for ${model.filename}: expected $expectedSha, got $actualSha"
                    )
                }
            }

            sink.finalize(tempPath, finalPath)
            store.updateProgress(model.id, bytesDownloaded = downloaded, totalBytes = if (total > 0) total else downloaded)
            onProgress(1.0)
            // Mirror iOS: a finished download leaves the resume table (it's no longer in-flight).
            store.setState(model.id, PersistedDownload.State.COMPLETED)
            store.remove(model.id)
            return finalPath
        } catch (t: Throwable) {
            // Clear any partially-written final file (e.g. a cross-filesystem copy that failed
            // after the rename fallback) so no half-written model is left behind a passed gate (C3-4).
            runCatching { sink.truncate(finalPath) }
            store.setState(model.id, PersistedDownload.State.FAILED)
            if (t is DownloadException) throw t
            throw DownloadException("download failed for ${model.filename}: ${t.message}")
        }
    }
}
