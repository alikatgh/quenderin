package ai.quenderin.app

import ai.quenderin.core.DownloadCancelledException
import ai.quenderin.core.DownloadException
import ai.quenderin.core.JvmFileSink
import ai.quenderin.core.ModelDownloader
import ai.quenderin.core.ModelDownloadProgress
import ai.quenderin.core.AndroidModelSelector
import ai.quenderin.core.ModelRuntimeSupport
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelArtifacts
import ai.quenderin.core.ModelIntegrity
import ai.quenderin.core.DiskSpace
import android.content.Context
import java.io.File
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf

/**
 * Real [ModelDownloader] backed by [ModelDownloadWorker] + WorkManager, so a model fetch
 * survives the app being backgrounded or killed — the exact failure a foreground download
 * hits when the off-grid user switches apps mid-download. Drop-in for `MockModelDownloader`.
 *
 * The [download] contract is blocking ([ai.quenderin.core.OnboardingModel] calls it off the
 * main thread), so this enqueues a unique WorkManager job and blocks while mirroring its
 * progress. Because the work is WorkManager-managed it keeps running across process death,
 * and the core engine resumes byte-exact from the `.part` file on the next run.
 *
 * REQUIRES the Android SDK + AGP to build. Not part of the headless `kotlinc` check.
 */
class WorkManagerModelDownloader(
    private val context: Context,
    private val pollMs: Long = 250,
    // Q-584: the WorkManager network constraint. Wi-Fi-only (the default DownloadPolicy) → UNMETERED,
    // so a deferred/parked download never runs on metered cellular even if the OnboardingModel gate was
    // somehow bypassed OR Wi-Fi drops mid-download. When Q-578's cellular opt-in toggle lands, the app
    // passes `false` for a policy of wifiOrCellular.
    private val requireUnmetered: Boolean = true,
) : ModelDownloader {

    /** (path, size) of the last file that passed the sha gate, so OnboardingModel's [needsFetch]
     *  preflight followed by [download] doesn't stream the multi-GB SHA-256 twice per restore/switch.
     *  Mirrors ModelDownloadEngine's memo. */
    @Volatile
    private var lastVerified: Pair<String, Long>? = null

    /** The on-disk file for [model] if it passes the pinned-sha gate, else null. */
    private fun verifiedExistingFile(model: ModelEntry): File? {
        ModelArtifacts.validate(model)
        val existing = File(context.filesDir, "models/${model.filename}")
        // Split verification belongs to the foreground worker so cancelUniqueWork can stop hashes.
        check(model.artifacts.isEmpty())
        if (!existing.isFile) return null
        if (model.downloadBytes != null && existing.length() != model.downloadBytes) return null
        if (lastVerified == existing.absolutePath to existing.length()) return existing
        val expected = model.sha256
        if (!ModelIntegrity.hasGGUFMagic(JvmFileSink().head(existing.absolutePath, 4))) return null
        if (expected != null && !JvmFileSink().sha256(existing.absolutePath).equals(expected, ignoreCase = true)) return null
        lastVerified = existing.absolutePath to existing.length()
        return existing
    }

    override fun needsFetch(model: ModelEntry): Boolean {
        ModelArtifacts.validate(model)
        if (!ModelRuntimeSupport.supports(model)) return true
        if (model.artifacts.isNotEmpty()) {
            // Candidate only: download() always verifies it in an offline-capable cancellable job.
            return !ModelArtifacts.hasCompleteFileSet(model, File(context.filesDir, "models").absolutePath)
        }
        return verifiedExistingFile(model) == null
    }

    override fun remainingDownloadBytes(model: ModelEntry): Long =
        ModelArtifacts.estimatedRemainingDownloadBytes(model, File(context.filesDir, "models").absolutePath)

    override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String =
        downloadWithProgress(model) { progress ->
            if (progress is ModelDownloadProgress.Downloading) onProgress(progress.fraction)
        }

    override fun downloadWithProgress(model: ModelEntry, onProgress: (ModelDownloadProgress) -> Unit): String {
        ModelArtifacts.validate(model)
        if (!ModelRuntimeSupport.supports(model)) throw DownloadException(ModelRuntimeSupport.unavailableMessage(model))
        if (ModelRuntimeSupport.requiresMemoryGate(model)) {
            val fitness = AndroidModelSelector.fitness(model, context.probeDeviceProfile())
            if (!fitness.canLoad) throw DownloadException(fitness.message)
        }
        // Already fully on disk and integrity-verified → hand it back without waking WorkManager.
        // This is what makes the cold-launch restore work OFFLINE: the CONNECTED constraint below
        // would otherwise park the work at ENQUEUED until the network returns, hanging a "load the
        // model you already have" call forever. Twin of the Swift install() skip-download path
        // (testInstallSkipsDownloadWhenFileExists) — the sha gate still rejects a corrupted file,
        // which then falls through to a real (resumable) download.
        if (model.artifacts.isEmpty()) {
            verifiedExistingFile(model)?.let {
                onProgress(ModelDownloadProgress.Downloading(1.0))
                return it.absolutePath
            }
        }
        lastVerified = null

        val verifyOnly = model.artifacts.isNotEmpty() &&
            ModelArtifacts.hasCompleteFileSet(model, File(context.filesDir, "models").absolutePath)

        if (!verifyOnly) {
            val storage = DiskSpace.check(model, context.filesDir.usableSpace,
                remainingDownloadBytes = remainingDownloadBytes(model))
            if (!storage.hasRoom) throw DownloadException(storage.message)
        }

        val workManager = WorkManager.getInstance(context)

        val constraints = Constraints.Builder()
            // Q-584: UNMETERED under the Wi-Fi-only default (was CONNECTED = any network). The
            // DownloadPolicy gate in OnboardingModel is the primary check; this is the WorkManager-layer
            // backstop so a metered cellular pull can't slip through a deferred/parked download.
            .setRequiredNetworkType(if (verifyOnly) NetworkType.NOT_REQUIRED
                else if (requireUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresStorageNotLow(!verifyOnly)
            .build()

        val request = OneTimeWorkRequestBuilder<ModelDownloadWorker>()
            .setConstraints(constraints)
            .setInputData(workDataOf(ModelDownloadWorker.KEY_MODEL_ID to model.id,
                ModelDownloadWorker.KEY_VERIFY_ONLY to verifyOnly))
            .build()

        val uniqueName = "download:${model.id}"
        // KEEP: if a download for this model is already running (e.g. resumed after relaunch),
        // attach to it instead of starting a second one.
        // A finished on-disk set can replace an old network-constrained job and verify offline.
        workManager.enqueueUniqueWork(uniqueName, if (verifyOnly) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP, request)

        while (true) {
            val info = workManager.getWorkInfosForUniqueWork(uniqueName).get().firstOrNull()
                ?: throw DownloadException("download work vanished for ${model.id}")

            val progress = info.progress
            if (progress.getString(ModelDownloadWorker.KEY_STAGE) == "verifying") {
                val total = model.artifacts.size
                onProgress(ModelDownloadProgress.Verifying(
                    progress.getInt(ModelDownloadWorker.KEY_VERIFIED_FILES, 0).coerceIn(0, total), total))
            } else if (progress.keyValueMap.containsKey(ModelDownloadWorker.KEY_PROGRESS)) {
                onProgress(ModelDownloadProgress.Downloading(progress.getDouble(ModelDownloadWorker.KEY_PROGRESS, 0.0)))
            }

            when (info.state) {
                WorkInfo.State.SUCCEEDED -> {
                    val path = info.outputData.getString(ModelDownloadWorker.KEY_PATH)
                        ?: throw DownloadException("download finished without a path for ${model.id}")
                    if (model.artifacts.isNotEmpty() && (path != File(context.filesDir, "models/${model.filename}").absolutePath ||
                            !ModelArtifacts.hasCompleteFileSet(model, File(context.filesDir, "models").absolutePath))) {
                        throw DownloadException("Model is incomplete or corrupt: every GGUF shard must pass integrity verification.")
                    }
                    return path
                }
                WorkInfo.State.FAILED ->
                    throw DownloadException(
                        info.outputData.getString(ModelDownloadWorker.KEY_ERROR) ?: "download failed for ${model.id}"
                    )
                WorkInfo.State.CANCELLED ->
                    // A user cancel (see [cancel]) is a change of mind, not a failure — the typed
                    // exception lets OnboardingModel return to the recommendation instead of Failed.
                    throw DownloadCancelledException("download cancelled for ${model.id}")
                else -> Thread.sleep(pollMs) // ENQUEUED / RUNNING / BLOCKED — keep mirroring progress
            }
        }
    }

    /** Cancel an in-flight download: WorkManager flips the worker's `isStopped`, the engine keeps
     *  the `.part` for a future resume, and the polling loop above surfaces the typed cancel. */
    fun cancel(model: ModelEntry) {
        WorkManager.getInstance(context).cancelUniqueWork("download:${model.id}")
    }
}
