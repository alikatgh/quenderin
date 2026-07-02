package ai.quenderin.app

import ai.quenderin.core.DownloadCancelledException
import ai.quenderin.core.DownloadException
import ai.quenderin.core.ModelDownloader
import ai.quenderin.core.ModelEntry
import android.content.Context
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
) : ModelDownloader {

    override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String {
        val workManager = WorkManager.getInstance(context)

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)   // gate Wi-Fi-only at the DownloadPolicy layer
            .setRequiresStorageNotLow(true)
            .build()

        val request = OneTimeWorkRequestBuilder<ModelDownloadWorker>()
            .setConstraints(constraints)
            .setInputData(workDataOf(ModelDownloadWorker.KEY_MODEL_ID to model.id))
            .build()

        val uniqueName = "download:${model.id}"
        // KEEP: if a download for this model is already running (e.g. resumed after relaunch),
        // attach to it instead of starting a second one.
        workManager.enqueueUniqueWork(uniqueName, ExistingWorkPolicy.KEEP, request)

        while (true) {
            val info = workManager.getWorkInfosForUniqueWork(uniqueName).get().firstOrNull()
                ?: throw DownloadException("download work vanished for ${model.id}")

            onProgress(info.progress.getDouble(ModelDownloadWorker.KEY_PROGRESS, 0.0))

            when (info.state) {
                WorkInfo.State.SUCCEEDED ->
                    return info.outputData.getString(ModelDownloadWorker.KEY_PATH)
                        ?: throw DownloadException("download finished without a path for ${model.id}")
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
