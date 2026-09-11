package ai.quenderin.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

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

    /**
     * True when [openRange] returns a genuinely bounded segment (a 206 whose Content-Range starts
     * at `startBytes`), not the rest of the file. Default false so an [open]-only client keeps the
     * single-stream behavior — the engine parallelizes only when this is true.
     */
    val supportsBoundedRanges: Boolean get() = false

    /**
     * Bounded `Range: bytes=startBytes-endBytes` — one segment of a parallel download. Default
     * falls back to the unbounded resume form so existing clients still compile; the engine then
     * never takes the parallel path (see [supportsBoundedRanges]).
     */
    fun openRange(url: String, startBytes: Long, endBytes: Long): RangeResponse = open(url, startBytes)
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

    /**
     * True when [preallocate] + [writeAt] are implemented — the parallel path needs both (it
     * writes disjoint byte ranges into one pre-sized file concurrently). Default false.
     */
    val supportsPositionedWrites: Boolean get() = false

    /** Grow [path] to exactly [size] bytes (zero-filled) so positioned writes land correctly. */
    fun preallocate(path: String, size: Long) {}

    /** Write [bytes] at [offset]; the parallel path calls this from several threads on disjoint ranges. */
    fun writeAt(path: String, offset: Long, bytes: ByteArray) {
        throw UnsupportedOperationException("positioned writes not supported by this FileSink")
    }
}

/** Thrown when a download cannot complete; carries a clear, surfaceable reason. */
open class DownloadException(message: String) : Exception(message)

/** A cooperative cancel (WorkManager stop / model switch), NOT a failure: the `.part` is kept and the
 *  row left PAUSED so the next launch resumes. A subtype of [DownloadException] so existing callers
 *  that catch the base type are unaffected. */
class DownloadCancelledException(message: String) : DownloadException(message)

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
    /** Polled each chunk so a WorkManager stop / model switch can cooperatively abort a multi-GB
     *  transfer (the WorkManager worker passes `{ isStopped }`). Default never-cancel keeps the mock
     *  and onboarding callers unchanged. (Audit: chunk loop not cancellable.) */
    private val isCancelled: () -> Boolean = { false },
    /** True on a metered connection — the parallel path opens fewer connections (money + battery). */
    private val isCellular: () -> Boolean = { false },
) : ModelDownloader {

    /** (path, size) of the last file that passed the full integrity gate, so [needsFetch] followed by
     *  [download] in the same flow (launch restore, model switch) doesn't stream the multi-GB SHA-256
     *  twice. Same-size TOCTOU window is milliseconds inside one install call — the Swift twin's
     *  verify-then-load has the identical window. Cleared whenever the final file is discarded. */
    @Volatile
    private var lastVerified: Pair<String, Long>? = null

    /** Path of an existing, integrity-verified (magic + pinned SHA-256) download at the final
     *  destination, or null when a real fetch is needed. The C3 gate for reusing leftovers. */
    private fun verifiedExistingPath(model: ModelEntry): String? {
        val finalPath = "$destinationDir/${model.filename}"
        val size = sink.existingSize(finalPath)
        if (size <= 0) return null
        if (lastVerified == finalPath to size) return finalPath
        if (!ModelIntegrity.hasGGUFMagic(sink.head(finalPath, 4))) return null
        val expectedSha = model.sha256
        if (expectedSha != null && !sink.sha256(finalPath).equals(expectedSha, ignoreCase = true)) return null
        lastVerified = finalPath to size
        return finalPath
    }

    override fun needsFetch(model: ModelEntry): Boolean = verifiedExistingPath(model) == null

    override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String {
        val finalPath = "$destinationDir/${model.filename}"
        val tempPath = "$finalPath.part"

        // Already downloaded — e.g. onboarding re-running after a reinstall, a model switch
        // falling back via restore(), or a stale WorkManager re-run hitting a finished job.
        // Verify (not just "file present") before trusting it, same gate a fresh download
        // passes, so a corrupt/tampered finalPath can't be silently reused (C3). This is the
        // "returns the existing path without re-fetching" contract OnboardingModel.restore()
        // already documents — it just wasn't implemented here, so every re-entry re-fetched the
        // full multi-GB file from byte 0.
        verifiedExistingPath(model)?.let {
            onProgress(1.0)
            return it
        }
        // Existing bytes failed the gate — don't trust them; discard and fall through to a real
        // download (Swift parity: install() deletes on ANY verify failure, bad magic included).
        if (sink.existingSize(finalPath) > 0) {
            sink.truncate(finalPath)
            lastVerified = null
        }

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
            // Parallel path: only for a FRESH download on a client + sink that support bounded ranges
            // and positioned writes. A partial already on disk keeps the single-stream resume below.
            if (existing == 0L && http.supportsBoundedRanges && sink.supportsPositionedWrites) {
                val probe = http.openRange(model.url, 0, 0)   // 1-byte probe, just for the total size
                probe.body.forEach { /* drain to close the connection */ }
                if (probe.resumed && probe.totalBytes > 0) {
                    val downloaded = downloadParallel(model, tempPath, probe.totalBytes, onProgress)
                    return verifyAndFinalize(model, tempPath, finalPath, downloaded, probe.totalBytes, onProgress)
                }
                // total unknown → fall through to the single-stream path below
            }

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
                if (isCancelled()) {
                    // Cooperative abort (model switch / WorkManager stop). The catch keeps the .part on
                    // disk and marks the row PAUSED so the next launch RESUMES — unlike an integrity
                    // failure, which discards. (Audit: chunk loop not cancellable.)
                    throw DownloadCancelledException("download cancelled for ${model.filename}")
                }
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

            return verifyAndFinalize(model, tempPath, finalPath, downloaded, total, onProgress)
        } catch (t: Throwable) {
            // A cooperative cancel is not a failure: keep the .part and leave the row PAUSED so the
            // next launch resumes from here. Don't truncate the final file or mark FAILED.
            if (t is DownloadCancelledException) {
                store.setState(model.id, PersistedDownload.State.PAUSED)
                throw t
            }
            // Clear any partially-written final file (e.g. a cross-filesystem copy that failed
            // after the rename fallback) so no half-written model is left behind a passed gate (C3-4).
            runCatching { sink.truncate(finalPath) }
            lastVerified = null
            store.setState(model.id, PersistedDownload.State.FAILED)
            if (t is DownloadException) throw t
            throw DownloadException("download failed for ${model.filename}: ${t.message}")
        }
    }

    /**
     * N concurrent bounded-range GETs into disjoint regions of a pre-sized `.part` file. Uses plain
     * `java.util.concurrent` (the core is dependency-free — no coroutines). Each segment owns a
     * private [Range] so the writers never touch the same bytes; the C3 gate runs once, after.
     */
    private fun downloadParallel(model: ModelEntry, tempPath: String, total: Long,
                                 onProgress: (Double) -> Unit): Long {
        val count = DownloadSegments.connectionCount(total, isCellular = isCellular())
        val plan = DownloadSegments.plan(total, count)
        sink.preallocate(tempPath, total)

        val downloaded = AtomicLong(0)
        val firstError = AtomicReference<Throwable?>(null)
        val latch = CountDownLatch(plan.segments.size)
        val executor = Executors.newFixedThreadPool(plan.segments.size)
        val progressLock = Any()
        var lastReported = 0.0

        for (segment in plan.segments) {
            executor.execute {
                try {
                    var offset = segment.start
                    val response = http.openRange(model.url, segment.start, segment.end)
                    for (chunk in response.body) {
                        if (isCancelled()) {
                            throw DownloadCancelledException("download cancelled for ${model.filename}")
                        }
                        if (chunk.isEmpty()) continue
                        sink.writeAt(tempPath, offset, chunk)
                        offset += chunk.size
                        val done = downloaded.addAndGet(chunk.size.toLong())
                        val fraction = (done.toDouble() / total).coerceIn(0.0, 1.0)
                        synchronized(progressLock) {
                            if (fraction - lastReported >= progressStep) {
                                lastReported = fraction
                                onProgress(fraction)
                                store.updateProgress(model.id, bytesDownloaded = done, totalBytes = total)
                            }
                        }
                    }
                } catch (t: Throwable) {
                    firstError.compareAndSet(null, t)
                } finally {
                    latch.countDown()
                }
            }
        }
        latch.await()
        executor.shutdown()
        firstError.get()?.let { throw it }
        return downloaded.get()
    }

    /**
     * The C3 integrity gate + atomic promote, shared by the single-stream and parallel paths.
     * Verifies the assembled bytes BEFORE promoting `.part` → final, so a MITM / poisoned mirror /
     * truncated file never becomes the active model. When the server sent no Content-Length
     * (`total <= 0`) the mandatory sha256 gate IS the completeness guarantee.
     */
    private fun verifyAndFinalize(model: ModelEntry, tempPath: String, finalPath: String,
                                  downloaded: Long, total: Long, onProgress: (Double) -> Unit): String {
        if (total > 0 && downloaded < total) {
            throw DownloadException(
                "incomplete download for ${model.filename}: got $downloaded of $total bytes"
            )
        }
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
        // The bytes at finalPath just passed the gate above — remember so the next
        // verifiedExistingPath (e.g. the load-failure restore() path) skips the re-hash.
        lastVerified = finalPath to downloaded
        store.updateProgress(model.id, bytesDownloaded = downloaded, totalBytes = if (total > 0) total else downloaded)
        onProgress(1.0)
        // Mirror iOS: a finished download leaves the resume table (it's no longer in-flight).
        store.setState(model.id, PersistedDownload.State.COMPLETED)
        store.remove(model.id)
        return finalPath
    }
}
