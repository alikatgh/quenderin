package ai.quenderin.core

import kotlin.math.roundToInt

/**
 * What sustained on-device generation does to heat and battery — the honest "what to
 * expect" surface. Calibrated from measured 2024–2026 phone data (apple/REALITY.md);
 * identical model to the iOS `ThermalBattery`.
 */
data class ThermalBatteryEstimate(
    /** Battery (mAh) to generate 1,000 tokens. Memory-bound, so ≈ const × params. */
    val mAhPer1KTokens: Double,
    /** Battery used per hour of CONTINUOUS active generation, as % of this device's battery. */
    val activeDrainPercentPerHour: Double,
    /** Sustained tok/s once the SoC thermally throttles (minutes into continuous load). */
    val sustainedTokensPerSecond: Double,
    /** Fraction of peak speed retained when throttled (measured drops span 10–44%). */
    val throttledFraction: Double,
    /** Plain verdict for bursty chat — the 95% case (barely warms, trivial cost). */
    val chatVerdict: String,
    /** Honest warning for sustained / agent-loop use (heat + throttle + drain). */
    val sustainedVerdict: String,
    /** % of battery a single typical (~300-token) reply costs — the figure [chatVerdict] states.
     *  Exposed so the UI can recompose the verdict in the user's language. */
    val replyPercent: Double,
    /** % of peak speed LOST once throttled (100·(1−throttledFraction)) — the figure
     *  [sustainedVerdict] states; exposed for the localized UI recomposition. */
    val throttledLossPercent: Double,
)

object ThermalBattery {

    /** ≈ 35 mAh per 1,000 tokens for a 7B Q4 (measured) → 35 / 7 ≈ 5 mAh per billion params. */
    const val MAH_PER_1K_TOKENS_PER_BILLION_PARAMS = 5.0

    /** Speed retained once throttled. Measured losses 10–44%; ~35%-loss midpoint. */
    const val THROTTLED_FRACTION = 0.65

    const val TYPICAL_REPLY_TOKENS = 300.0

    fun estimate(
        model: ModelEntry,
        soc: AndroidSoc,
        batteryMAh: Double,
        peakTokensPerSecond: Double,
    ): ThermalBatteryEstimate {
        val mAhPer1K = MAH_PER_1K_TOKENS_PER_BILLION_PARAMS * model.paramsBillions
        val sustainedTokS = peakTokensPerSecond * THROTTLED_FRACTION

        val mAhPerHour = sustainedTokS * 3600.0 * (mAhPer1K / 1000.0)
        val drainPctPerHour = if (batteryMAh > 0) mAhPerHour / batteryMAh * 100.0 else 0.0

        val replyPct = if (batteryMAh > 0) mAhPer1K * (TYPICAL_REPLY_TOKENS / 1000.0) / batteryMAh * 100.0 else 0.0
        val lossPct = ((1 - THROTTLED_FRACTION) * 100).roundToInt()
        val replyStr = if (replyPct < 0.1) "0.1" else "%.1f".format(replyPct)

        return ThermalBatteryEstimate(
            mAhPer1KTokens = mAhPer1K,
            activeDrainPercentPerHour = drainPctPerHour,
            sustainedTokensPerSecond = sustainedTokS,
            throttledFraction = THROTTLED_FRACTION,
            chatVerdict = "Light for chat — a typical reply costs ~$replyStr% battery and barely warms the phone.",
            sustainedVerdict = "Sustained / agent use: warms and throttles ~$lossPct% slower after a few minutes, " +
                "drawing ~${drainPctPerHour.roundToInt()}%/hr of continuous generation.",
            replyPercent = replyPct,
            throttledLossPercent = lossPct.toDouble(),
        )
    }
}
