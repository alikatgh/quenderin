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
     * Count "big" (performance-capable) cores by reading each `cpuN/cpufreq/cpuinfo_max_freq` and
     * counting every core clocked ABOVE the slowest (LITTLE) cluster — i.e. the prime + performance
     * cores together, which is what should run matmul-heavy decode.
     *
     * NOT "cores at the single global max": modern SoCs are TRI-cluster (e.g. Snapdragon 8 Gen 2 =
     * 1 prime @3.36 GHz + 4 performance @2.8 GHz + 3 efficiency @2.0 GHz). Counting only the global
     * max frequency returns the **1** prime core, which pinned inference to a SINGLE thread — the
     * ~5–8× slowdown this fixes (BUG_JOURNAL: "Android decode ran single-threaded"). Above-the-LITTLE
     * yields 5 here. A homogeneous SoC (no slower cluster) has every core as "big" → total count.
     * Pass [cpuDir] for testing (default `/sys/devices/system/cpu`). `null` on any failure.
     */
    fun performanceCoreCount(cpuDir: File = File("/sys/devices/system/cpu")): Int? = runCatching {
        val cpus = cpuDir.listFiles { f -> f.isDirectory && f.name.matches(Regex("cpu[0-9]+")) }
            ?: return null
        val freqs = cpus.mapNotNull { core ->
            File(core, "cpufreq/cpuinfo_max_freq").takeIf { it.exists() }?.readText()?.trim()?.toLongOrNull()
        }
        if (freqs.isEmpty()) return null
        val littleFreq = freqs.min()
        val big = freqs.count { it > littleFreq }
        // Homogeneous SoC (all cores identical) → no LITTLE cluster to exclude → every core is "big".
        if (big > 0) big else freqs.size
    }.getOrNull()
}
