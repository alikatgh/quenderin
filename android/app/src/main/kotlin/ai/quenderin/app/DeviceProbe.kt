package ai.quenderin.app

import ai.quenderin.core.AndroidDeviceProfile
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs

/**
 * Build the rich device profile the AndroidModelSelector needs: RAM (ActivityManager), SoC
 * (Build.SOC_MODEL on API 31+, else Build.HARDWARE), and free disk (StatFs). Battery capacity has
 * no clean public API, so it defaults (PowerProfile reflection is a follow-up). The native-memory
 * budget is derived inside AndroidDeviceProfile.from.
 *
 * ONE probe for every surface that reasons about fit — onboarding's recommendation AND the
 * "Choose a model" sheet — so they can never print different numbers for the same phone.
 */
fun Context.probeDeviceProfile(): AndroidDeviceProfile {
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
