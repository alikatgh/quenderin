package ai.quenderin.app

import ai.quenderin.app.ui.AppRoot
import ai.quenderin.app.ui.QuenderinTheme
import ai.quenderin.core.DeviceProfile
import ai.quenderin.core.InferenceEngine
import ai.quenderin.core.LlamaEngine
import ai.quenderin.core.MockInferenceEngine
import ai.quenderin.core.MockModelDownloader
import ai.quenderin.core.ModelDownloader
import android.app.ActivityManager
import android.content.Context
import android.os.Bundle
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

    /** Real device RAM via ActivityManager — the input to the shared recommender. */
    private fun probeDevice(): DeviceProfile {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val gb = 1024.0 * 1024.0 * 1024.0
        return DeviceProfile(totalRamGB = info.totalMem / gb, freeRamGB = info.availMem / gb)
    }
}
