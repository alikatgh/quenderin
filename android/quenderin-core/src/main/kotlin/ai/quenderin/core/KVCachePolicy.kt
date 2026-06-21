package ai.quenderin.core

/**
 * The data type of the KV (attention) cache. The cache grows linearly with context length and, on a
 * memory-tight phone, is what tips a model that "fits by weights" into a low-memory kill. Quantizing
 * it to [Q8_0] roughly halves that cost at near-zero quality loss — so the same memory holds ~2× the
 * context (or the chosen context fits with real margin). Twin of iOS `KVCacheType`.
 *
 * We stop at [Q8_0]: it's safe on llama.cpp's standard (non-flash-attention) path for BOTH the K and
 * V cache. Going to q4_0 for the V cache requires flash attention — a separate change to enable +
 * validate on-device — so it's deliberately out of scope here.
 *
 * [nativeId] is the value passed to the JNI bridge (`nativeLoad`), which maps it to the ggml type.
 */
enum class KVCacheType(val nativeId: Int, val relativeCostPerToken: Double) {
    F16(0, 1.0),
    Q8_0(1, 0.53);   // 8 bits + block scale overhead ≈ 53% of f16
}

/**
 * Chooses the KV-cache dtype from the memory left after the model weights load. Roomy → keep
 * full-precision [KVCacheType.F16]; tight → [KVCacheType.Q8_0] so a constrained phone still gets a
 * usable context instead of a 512-token stub. Pure + testable. Twin of iOS `KVCachePolicy`; uses the
 * same headroom formula as [ContextWindow].
 */
object KVCachePolicy {
    fun recommend(appBudgetGb: Double, modelWeightsGb: Double): KVCacheType {
        val headroomGb = appBudgetGb - modelWeightsGb * 1.15   // free after weights + overhead
        // ≥ 1.2 GB free → f16 is affordable; below that, halve the cache to buy back context.
        return if (headroomGb >= 1.2) KVCacheType.F16 else KVCacheType.Q8_0
    }
}
