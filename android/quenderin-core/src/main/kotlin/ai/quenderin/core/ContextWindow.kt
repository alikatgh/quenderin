package ai.quenderin.core

/**
 * Picks the inference context window (`n_ctx`) for a device's total RAM. The KV cache grows with
 * `n_ctx` and sits on top of the model weights, so a fixed 4096 can push a memory-tight phone into
 * an OOM kill even for a model that "fits" by weights alone (audit M1). Smaller context on smaller
 * devices trades a shorter memory for not getting killed. Pure + deterministic → testable.
 * Twin of iOS `ContextWindow`.
 */
object ContextWindow {
    fun recommend(totalRamGb: Double): Int = when {
        totalRamGb < 4.0 -> 1024   // 2–3 GB phones: keep the KV cache small
        totalRamGb < 6.0 -> 2048   // 4 GB
        else -> 4096               // 6 GB+
    }
}
