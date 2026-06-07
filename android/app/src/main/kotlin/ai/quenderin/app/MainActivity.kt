package ai.quenderin.app

import ai.quenderin.app.ui.AppRoot
import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.core.AndroidDeviceProfile
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.LlamaEngine
import ai.quenderin.core.MockInferenceEngine
import ai.quenderin.core.MockModelDownloader
import ai.quenderin.core.ModelDownloader
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Bundle
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
            if (LlamaEngine.NATIVE_AVAILABLE) LlamaEngine() else MockInferenceEngine()
        val downloader: ModelDownloader = MockModelDownloader() // real WorkManager downloader = next milestone

        setContent {
            QuenderinTheme {
                AppRoot(engine = engine, downloader = downloader, probe = ::probeDevice)
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
