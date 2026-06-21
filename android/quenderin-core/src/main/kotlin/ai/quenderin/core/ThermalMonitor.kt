package ai.quenderin.core

/**
 * The device's thermal pressure. On a phone, sustained inference (an agent loop) throttles on
 * HEAT long before memory — so the launcher reads this and sheds threads to stay sustainable.
 * Twin of iOS `ThermalLevel`.
 */
enum class ThermalLevel { NOMINAL, FAIR, SERIOUS, CRITICAL }

/**
 * Maps Android's `PowerManager` thermal status → our [ThermalLevel]. Kept in the pure core (no
 * `android.os` dependency) by mapping the raw status int, so the app passes
 * `powerManager.currentThermalStatus` and the mapping stays unit-testable headlessly.
 *
 * Status ints (PowerManager.THERMAL_STATUS_*): 0 NONE, 1 LIGHT, 2 MODERATE, 3 SEVERE,
 * 4 CRITICAL, 5 EMERGENCY, 6 SHUTDOWN.
 */
object ThermalMonitor {
    fun levelFromStatus(status: Int): ThermalLevel = when (status) {
        0 -> ThermalLevel.NOMINAL            // NONE
        1, 2 -> ThermalLevel.FAIR            // LIGHT / MODERATE
        3, 4 -> ThermalLevel.SERIOUS         // SEVERE / CRITICAL
        else -> ThermalLevel.CRITICAL        // EMERGENCY / SHUTDOWN (and any unknown) → most cautious
    }
}

/**
 * Picks the inference thread count for a thermal level: drop threads as the device heats up so a
 * long generation doesn't throttle to a crawl (or get the app killed). Pure + testable.
 * Twin of iOS `ThermalThrottle`.
 */
object ThermalThrottle {
    fun recommendedThreads(level: ThermalLevel, baseThreads: Int): Int {
        val base = maxOf(1, baseThreads)
        return when (level) {
            ThermalLevel.NOMINAL -> base
            ThermalLevel.FAIR -> maxOf(1, base - 1)   // shed one core
            ThermalLevel.SERIOUS -> maxOf(1, base / 2) // halve
            ThermalLevel.CRITICAL -> 1                 // single core — minimal heat
        }
    }
}

/**
 * Re-tunes the thread count *during* a long generation as the thermal level moves — the load-time
 * snapshot only catches a phone that's already hot, but a 10-minute agent loop is what MAKES it hot.
 * The 4-level enum is its own hysteresis: re-tune only when the level changes AND the thread count
 * actually differs. Pure state machine, twin of iOS `ThermalGovernor`. (On Android the in-decode
 * sampling + `llama_set_n_threads` call live in the JNI C++ loop — the on-device wiring; this is the
 * shared, unit-tested decision logic.)
 */
class ThermalGovernor(baseThreadsParam: Int, initialLevel: ThermalLevel) {
    val baseThreads: Int = maxOf(1, baseThreadsParam)
    var currentLevel: ThermalLevel = initialLevel
        private set
    var currentThreads: Int = ThermalThrottle.recommendedThreads(initialLevel, maxOf(1, baseThreadsParam))
        private set

    /** Returns the new thread count to apply only when it should change; null when nothing changes. */
    fun update(level: ThermalLevel): Int? {
        if (level == currentLevel) return null
        currentLevel = level
        val n = ThermalThrottle.recommendedThreads(level, baseThreads)
        if (n == currentThreads) return null
        currentThreads = n
        return n
    }
}
