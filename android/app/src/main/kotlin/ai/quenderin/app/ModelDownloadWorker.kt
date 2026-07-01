package ai.quenderin.app

import ai.quenderin.core.DownloadCancelledException
import ai.quenderin.core.DownloadStore
import ai.quenderin.core.JvmFileSink
import ai.quenderin.core.JvmHttpRangeClient
import ai.quenderin.core.ModelCatalog
import ai.quenderin.core.ModelDownloadEngine
import ai.quenderin.core.PersistedDownload
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.ServiceInfo
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Background, survives-app-death model download — the Android twin of iOS
 * `BackgroundModelDownloader` (a background `URLSession`). WorkManager persists the request
 * across process death and re-runs [doWork], and the pure-core [ModelDownloadEngine] resumes
 * **byte-exact** from the half-written `.part` file. All transfer logic lives in
 * `:quenderin-core` (kotlinc-verified); this worker is only the thin SDK shell — the
 * foreground notification + WorkManager plumbing.
 *
 * REQUIRES the Android SDK + AGP to build (androidx.work). It is intentionally NOT part of
 * the headless `kotlinc` check that proves `:quenderin-core`. See `android/INTEGRATION.md`.
 */
class ModelDownloadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val modelId = inputData.getString(KEY_MODEL_ID)
            ?: return@withContext Result.failure(errorData("missing model id"))
        val model = ModelCatalog.entry(modelId)
            ?: return@withContext Result.failure(errorData("unknown model id: $modelId"))

        // Promote to a foreground service so a large GGUF keeps downloading while the app is away.
        setForeground(foregroundInfo(0.0, model.label))

        // DownloadStore's own doc comment promises progress "survives the app being suspended or
        // killed" via a persisted snapshot restored through the constructor (the iOS twin is a
        // file-backed actor) — load that snapshot here and wire onChange to write it back out, so a
        // relaunch's WorkInfo/DownloadStore query actually sees mid-flight state instead of an
        // always-empty table.
        val storeFile = File(applicationContext.filesDir, "download_store.txt")
        val store = DownloadStore(initial = loadSnapshot(storeFile))
        store.onChange = { saveSnapshot(storeFile, it) }

        val engine = ModelDownloadEngine(
            http = JvmHttpRangeClient(),
            sink = JvmFileSink(),
            store = store,
            destinationDir = applicationContext.filesDir.resolve("models").absolutePath,
            // WorkManager flips isStopped on cancel / constraint loss → abort the chunk loop
            // cooperatively instead of streaming a multi-GB file to /dev/null.
            isCancelled = { isStopped },
        )

        try {
            val path = engine.download(model) { fraction ->
                // Publish progress for any WorkInfo observer; also refresh the notification.
                setProgressAsync(workDataOf(KEY_PROGRESS to fraction))
                notify(fraction, model.label)
            }
            Result.success(workDataOf(KEY_PATH to path))
        } catch (t: DownloadCancelledException) {
            // Cooperative stop — WorkManager flipped isStopped (constraint loss like Wi-Fi off, or an
            // explicit cancel). The engine kept the `.part` + a PAUSED row, so ask WorkManager to RETRY:
            // it re-runs (and the engine resumes from the existing bytes) once constraints return.
            // Result.failure() here would be TERMINAL — the download would never auto-resume. (If the
            // work was explicitly cancelled, WorkManager ignores this Result anyway.)
            Result.retry()
        } catch (t: Throwable) {
            Result.failure(errorData(t.message ?: "download failed"))
        }
    }

    private fun foregroundInfo(fraction: Double, label: String): ForegroundInfo {
        val notification = buildNotification(fraction, label)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    private fun notify(fraction: Double, label: String) {
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(fraction, label))
    }

    private fun buildNotification(fraction: Double, label: String): android.app.Notification {
        ensureChannel()
        val pct = (fraction * 100).toInt().coerceIn(0, 100)
        return NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle("Downloading $label")
            .setContentText("$pct%")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setProgress(100, pct, fraction <= 0.0)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Model downloads", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun errorData(message: String) = workDataOf(KEY_ERROR to message)

    /**
     * Restore [DownloadStore]'s snapshot from disk (tab-delimited, one record per line — no JSON
     * dependency in this module). A missing/corrupt file just means "nothing to resume", not a
     * crash, since the on-disk `.part` file remains the source of truth for actual bytes.
     */
    private fun loadSnapshot(file: File): List<PersistedDownload> {
        if (!file.isFile) return emptyList()
        return file.readLines().mapNotNull { line ->
            val f = line.split('\t')
            if (f.size != 7) return@mapNotNull null
            runCatching {
                PersistedDownload(
                    modelId = f[0],
                    fileName = f[1],
                    urlString = f[2],
                    destinationPath = f[3],
                    bytesDownloaded = f[4].toLong(),
                    totalBytes = f[5].toLong(),
                    state = PersistedDownload.State.valueOf(f[6]),
                )
            }.getOrNull()
        }
    }

    /** Write [DownloadStore]'s snapshot back out — called from [DownloadStore.onChange]. */
    private fun saveSnapshot(file: File, records: List<PersistedDownload>) {
        val text = records.joinToString("\n") { r ->
            listOf(r.modelId, r.fileName, r.urlString, r.destinationPath, r.bytesDownloaded, r.totalBytes, r.state.name)
                .joinToString("\t")
        }
        file.parentFile?.mkdirs()
        file.writeText(text)
    }

    companion object {
        const val KEY_MODEL_ID = "model_id"
        const val KEY_PROGRESS = "progress"
        const val KEY_PATH = "path"
        const val KEY_ERROR = "error"
        private const val CHANNEL_ID = "model_downloads"
        private const val NOTIFICATION_ID = 0x6464
    }
}
