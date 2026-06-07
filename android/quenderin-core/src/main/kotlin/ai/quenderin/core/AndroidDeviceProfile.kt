package ai.quenderin.core

/**
 * Everything the Android model selector needs. Pure data so the selection LOGIC is
 * unit-tested on the JVM; the app builds the live profile from the Android framework
 * (`ActivityManager.MemoryInfo` for RAM, `Build.SOC_MODEL` for the chip, `StatFs` for
 * disk, `BatteryManager` for capacity) and hands it to the selector. Twin of iOS
 * `IOSDeviceProfile`.
 */
data class AndroidDeviceProfile(
    val deviceName: String,
    val soc: AndroidSoc,
    val totalRamGb: Double,
    /** Native-heap budget before the low-memory-killer is a risk (GB). THE constraint. */
    val appMemoryBudgetGb: Double,
    val freeDiskGb: Double,
    val batteryMAh: Double,
) {
    companion object {
        /** Default battery for a phone whose capacity we couldn't read. */
        const val FALLBACK_BATTERY_MAH = 4500.0

        /**
         * Build a profile from the raw facts the app reads off the framework. Derives the
         * native-memory budget from total RAM (see [AndroidSoc.nativeMemoryBudgetGB]).
         */
        fun from(
            deviceName: String,
            socModel: String?,
            totalRamGb: Double,
            freeDiskGb: Double,
            batteryMAh: Double = FALLBACK_BATTERY_MAH,
        ): AndroidDeviceProfile = AndroidDeviceProfile(
            deviceName = deviceName,
            soc = AndroidSoc.fromSocModel(socModel),
            totalRamGb = totalRamGb,
            appMemoryBudgetGb = AndroidSoc.nativeMemoryBudgetGB(totalRamGb),
            freeDiskGb = freeDiskGb,
            batteryMAh = batteryMAh,
        )
    }
}
