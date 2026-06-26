package ai.quenderin.app

import ai.quenderin.app.ui.AppRoot
import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.core.AndroidDeviceProfile
import ai.quenderin.core.AndroidSoc
import ai.quenderin.core.ConversationPersistence
import ai.quenderin.core.FileConversationPersistence
import ai.quenderin.core.GpuOffloadPlanner
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.LlamaEngine
import ai.quenderin.core.MockInferenceEngine
import ai.quenderin.core.ModelDownloader
import ai.quenderin.core.ThermalMonitor
import java.io.File
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

/**
 * The single Activity. Mirrors iOS `QuenderinApp` + `RootView`: it boots on the mock
 * engine so the whole onboarding → chat flow runs today, and auto-switches to the real
 * [LlamaEngine] the moment `libquenderin_llama.so` is present (link llama.cpp →
 * android/INTEGRATION.md). No code change to "go real" — same swap-nothing pattern as iOS.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val engine: InferenceEngine =
            if (LlamaEngine.NATIVE_AVAILABLE) {
                // Pass the native-heap budget (THE constraint), not total RAM — the engine sizes
                // n_ctx from it + the chosen model's footprint at load (footprint-aware M1).
                val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val totalRamGb = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
                    .totalMem / (1024.0 * 1024.0 * 1024.0)
                val budget = AndroidSoc.nativeMemoryBudgetGB(totalRamGb)
                val socModelStr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else Build.HARDWARE
                val soc = AndroidSoc.fromSocModel(socModelStr)
                val gpuLayers = GpuOffloadPlanner.recommend(soc, vulkanAvailable = BuildConfig.QUENDERIN_VULKAN)
                android.util.Log.i("Quenderin",
                    "GpuOffloadPlanner: ${GpuOffloadPlanner.rationale(soc, vulkanAvailable = BuildConfig.QUENDERIN_VULKAN)}")

                LlamaEngine(deviceBudgetGb = budget, gpuLayers = gpuLayers).also {
                    // Seed the engine with the device's current thermal pressure so the first model
                    // load already sheds threads if the phone is hot (PowerManager is API 29+).
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        it.thermalLevel = ThermalMonitor.levelFromStatus(pm.currentThermalStatus)
                    }
                }
            } else {
                MockInferenceEngine()
            }
        // Real, resumable downloader that survives app death (WorkManager + the pure-core
        // ModelDownloadEngine). MockModelDownloader stays available for previews/tests.
        val downloader: ModelDownloader = WorkManagerModelDownloader(applicationContext)
        // On-device conversation history: transcripts + index under filesDir, never a server.
        val conversations: ConversationPersistence = FileConversationPersistence(File(filesDir, "conversations"))

        setContent {
            QuenderinTheme {
                AppRoot(engine = engine, downloader = downloader, probe = ::probeDevice, conversations = conversations)
            }
        }
    }

    /**
     * Build the rich device profile the AndroidModelSelector needs: RAM (ActivityManager),
     * SoC (Build.SOC_MODEL on API 31+, else Build.HARDWARE), and free disk (StatFs).
     * Battery capacity has no clean public API, so it defaults (PowerProfile reflection is
     * a follow-up). The native-memory budget is derived inside AndroidDeviceProfile.from.
     */
    private fun probeDevice(): AndroidDeviceProfile {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val gb = 1024.0 * 1024.0 * 1024.0
        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else Build.HARDWARE
        val freeDiskGb = StatFs(filesDir.path).availableBytes / 1_000_000_000.0
        return AndroidDeviceProfile.from(
            deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
            socModel = socModel,
            totalRamGb = info.totalMem / gb,
            freeDiskGb = freeDiskGb,
        )
    }
}
