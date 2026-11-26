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

    /**
     * Cache-aware: a quantized KV cache costs less per token, so the *same* KV-memory budget holds
     * proportionally more tokens. Size the f16 context for the headroom, then scale by the inverse
     * per-token cost of the chosen dtype (q8_0 ≈ +90% context for the same memory), clamped to a
     * sane ceiling and rounded to a 256-token multiple. The [KVCacheType.F16] case is identical to
     * the 2-arg overload, so existing behaviour is unchanged unless quantization is requested.
     */
    fun recommend(appBudgetGb: Double, modelWeightsGb: Double, kvCacheType: KVCacheType): Int {
        val base = recommend(appBudgetGb, modelWeightsGb)
        val scaled = base / kvCacheType.relativeCostPerToken
        val rounded = Math.round(scaled / 256.0).toInt() * 256
        return rounded.coerceIn(256, 8192)
    }

    /**
     * Conservative f16 KV-cache footprint per cached token (0.5 MiB/token).
     * Covers typical ≤8B–14B GQA models (~0.15 MiB/token) with margin plus MHA 7B models
     * (~0.5 MiB/token) so a manual context choice never silently oversubscribes native-heap headroom.
     * Scaled by [KVCacheType.relativeCostPerToken] (e.g. `0.53` for `Q8_0`).
     */
    const val BASE_F16_KV_MB_PER_TOKEN: Double = 0.5

    /** Estimated KV-cache memory in GiB for [tokens] at the given [kvCacheType]. */
    fun estimatedKvGb(tokens: Int, kvCacheType: KVCacheType): Double {
        if (tokens <= 0) return 0.0
        return (tokens.toDouble() * BASE_F16_KV_MB_PER_TOKEN * kvCacheType.relativeCostPerToken) / 1024.0
    }

    /**
     * Resolves a user's [ContextLengthChoice] against the device's app-memory headroom.
     * - [ContextLengthChoice.AUTO]: exact 3-arg [recommend] result, `warning == null`.
     * - Manual (`K2`/`K4`/`K8`): ALWAYS checked against the estimated KV headroom:
     *   - If `estimatedKvGb(requested) <= headroomGb`, returns `requested`, with
     *     [ContextWarning.MORE_MEMORY] when `requested > autoTokens` or `null` otherwise.
     *   - Otherwise clamps to the largest of `8192 / 4096 / 2048` that fits (never below `2048`;
     *     if even `2048` does not fit, returns `2048`) with [ContextWarning.EXCEEDS_BUDGET].
     */
    fun resolve(
        choice: ContextLengthChoice,
        appBudgetGb: Double,
        modelWeightsGb: Double,
        kvCacheType: KVCacheType,
    ): ContextResolution {
        val autoTokens = recommend(appBudgetGb, modelWeightsGb, kvCacheType)
        val requested = choice.requestedTokens ?: return ContextResolution(autoTokens, null)
        val headroomGb = appBudgetGb - modelWeightsGb * 1.15
        fun fits(tokens: Int): Boolean = headroomGb > 0.0 && estimatedKvGb(tokens, kvCacheType) <= headroomGb
        if (fits(requested)) {
            val warning = if (requested > autoTokens) ContextWarning.MORE_MEMORY else null
            return ContextResolution(requested, warning)
        }
        val clamped = MANUAL_TIERS_DESC.firstOrNull(::fits) ?: 2048
        return ContextResolution(clamped, ContextWarning.EXCEEDS_BUDGET)
    }

    private val MANUAL_TIERS_DESC = intArrayOf(8192, 4096, 2048)

    /**
     * Engine load-time sizing: resolves [choice] via [resolve] and applies an optional model- or
     * specialist-specific context ceiling ([maxContextTokens]). For [ContextLengthChoice.AUTO],
     * produces the exact same token count as [recommend] clamped to [maxContextTokens].
     * Twin of Swift `ContextWindow.resolveForLoad`.
     */
    fun resolveForLoad(
        choice: ContextLengthChoice,
        appBudgetGb: Double,
        modelWeightsGb: Double,
        kvCacheType: KVCacheType,
        maxContextTokens: Int? = null,
    ): Int {
        val resolved = resolve(choice, appBudgetGb, modelWeightsGb, kvCacheType).tokens
        return if (maxContextTokens != null) minOf(resolved, maxContextTokens) else resolved
    }
}

/**
 * User-selectable context length preference. Default is [AUTO] (matches existing behaviour).
 * Twin of Swift `ContextLengthChoice`.
 */
enum class ContextLengthChoice(val rawValue: String, val requestedTokens: Int?) {
    AUTO("auto", null),
    K2("2048", 2048),
    K4("4096", 4096),
    K8("8192", 8192);

    companion object {
        val DEFAULT: ContextLengthChoice = AUTO

        fun fromRawValue(raw: String): ContextLengthChoice? =
            entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * Memory advisory produced when resolving a manual [ContextLengthChoice].
 * Twin of Swift `ContextWarning`.
 */
enum class ContextWarning {
    /** Requested length is above Auto but still fits the estimated KV headroom. */
    MORE_MEMORY,
    /** Requested length exceeds estimated KV headroom and was clamped down to Auto. */
    EXCEEDS_BUDGET,
}

/**
 * Result of resolving a [ContextLengthChoice] for a device and model.
 * Twin of Swift `ContextResolution`.
 */
data class ContextResolution(
    val tokens: Int,
    val warning: ContextWarning?,
) {
    /** Short English advisory text for the UI, or `null` when there is no warning. */
    val warningText: String?
        get() = when (warning) {
            null -> null
            ContextWarning.MORE_MEMORY -> "Uses more memory. Long chats may be slower."
            ContextWarning.EXCEEDS_BUDGET -> "Not enough memory on this device for this length; using $tokens tokens."
        }
}
