package ai.quenderin.app

import ai.quenderin.core.DownloadStore
import ai.quenderin.core.JvmFileSink
import ai.quenderin.core.JvmHttpRangeClient
import ai.quenderin.core.ModelCatalog
import ai.quenderin.core.ModelDownloadEngine
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

        val engine = ModelDownloadEngine(
            http = JvmHttpRangeClient(),
            sink = JvmFileSink(),
            store = DownloadStore(),
            destinationDir = applicationContext.filesDir.resolve("models").absolutePath,
        )

        try {
            val path = engine.download(model) { fraction ->
                // Publish progress for any WorkInfo observer; also refresh the notification.
                setProgressAsync(workDataOf(KEY_PROGRESS to fraction))
                notify(fraction, model.label)
            }
            Result.success(workDataOf(KEY_PATH to path))
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

    companion object {
        const val KEY_MODEL_ID = "model_id"
        const val KEY_PROGRESS = "progress"
        const val KEY_PATH = "path"
        const val KEY_ERROR = "error"
        private const val CHANNEL_ID = "model_downloads"
        private const val NOTIFICATION_ID = 0x6464
    }
}
