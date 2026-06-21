package ai.quenderin.core

import java.io.File

/**
 * Picks the inference thread count. On big.LITTLE SoCs scheduling matmul-heavy decode onto the
 * efficiency (LITTLE) cores is **slower and hotter** than using the big cores alone — the slow
 * cores bottleneck the others and add heat. Target the big-core count, clamped, with the old
 * "all-but-one" heuristic as a fallback. Pure + deterministic → testable. Twin of iOS `ThreadPlanner`.
 */
object ThreadPlanner {
    fun recommend(performanceCores: Int?, totalCores: Int): Int {
        val total = maxOf(1, totalCores)
        val p = performanceCores
        return if (p != null && p in 1..total) p else maxOf(1, total - 1)
    }

    /**
     * Count "big" cores by reading each `cpuN/cpufreq/cpuinfo_max_freq` and counting those at the
     * global max frequency (big.LITTLE big cores clock higher; a homogeneous SoC yields all cores).
     * Pass [cpuDir] for testing (default `/sys/devices/system/cpu`). `null` on any failure.
     */
    fun performanceCoreCount(cpuDir: File = File("/sys/devices/system/cpu")): Int? = runCatching {
        val cpus = cpuDir.listFiles { f -> f.isDirectory && f.name.matches(Regex("cpu[0-9]+")) }
            ?: return null
        val freqs = cpus.mapNotNull { core ->
            File(core, "cpufreq/cpuinfo_max_freq").takeIf { it.exists() }?.readText()?.trim()?.toLongOrNull()
        }
        if (freqs.isEmpty()) null else freqs.count { it == freqs.max() }
    }.getOrNull()
}
