package ai.quenderin.core

/**
 * Picks the inference context window (`n_ctx`) for a device's total RAM. The KV cache grows with
 * `n_ctx` and sits on top of the model weights, so a fixed 4096 can push a memory-tight phone into
 * an OOM kill even for a model that "fits" by weights alone (audit M1). Smaller context on smaller
 * devices trades a shorter memory for not getting killed. Pure + deterministic → testable.
 * Twin of iOS `ContextWindow`.
 */
object ContextWindow {
    /** RAM-band fallback (used when the chosen model isn't known yet). */
    fun recommend(totalRamGb: Double): Int = when {
        totalRamGb < 4.0 -> 1024   // 2–3 GB phones: keep the KV cache small
        totalRamGb < 6.0 -> 2048   // 4 GB
        else -> 4096               // 6 GB+
    }

    /**
     * Footprint-aware: size `n_ctx` from the device's real app-memory budget AND the chosen model's
     * weights, so a 1B leaves room for a big context while a 7B on the same phone is capped tight —
     * the headroom after the weights load is what's left for the KV cache. [appBudgetGb] is the
     * *app-memory* budget (native-heap on Android), NOT total RAM.
     */
    fun recommend(appBudgetGb: Double, modelWeightsGb: Double): Int {
        val headroomGb = appBudgetGb - modelWeightsGb * 1.15   // free after weights + overhead
        return when {
            headroomGb < 0.25 -> 512    // barely fits the weights — minimal KV cache
            headroomGb < 0.6 -> 1024
            headroomGb < 1.2 -> 2048
            else -> 4096
        }
    }
}
