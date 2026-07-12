package ai.quenderin.app.ui

import ai.quenderin.app.R
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelSelection
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import java.util.Locale

// ── Localized onboarding model-fitness copy ──────────────────────────────────────────
// The core AndroidModelSelector / ThermalBattery compose these sentences in English (kept for
// CoreVerify + the iOS twin). Here we RECOMPOSE them in the user's language from the same structured
// fields, so ru/ko/ja/zh users don't see an English paragraph on the recommendation screen. Numbers
// are formatted with the app locale (so "1.0" → "1,0" in ru) and passed as %n$s args.

private fun f1(v: Double) = String.format(Locale.getDefault(), "%.1f", v)
private fun f0(v: Double) = String.format(Locale.getDefault(), "%.0f", v)

/** "0.8 GB download" → localized "0.8 GB · загрузка" (strips the English suffix, re-adds it localized). */
@Composable
fun localizedSizeLabel(model: ModelEntry): String =
    stringResource(R.string.model_size_download, model.sizeLabel.removeSuffix(" download"))

/** The speed adverb the rationale embeds — same thresholds as AndroidModelSelector.speedWord. */
@Composable
private fun localizedSpeedWord(tokensPerSecond: Double): String = stringResource(
    when {
        tokensPerSecond >= 15 -> R.string.fitness_speed_comfortably
        tokensPerSecond >= 9 -> R.string.fitness_speed_smoothly
        else -> R.string.fitness_speed_usably
    }
)

/** The device rationale ("X for your DEVICE: ~N tok/s…"), rebuilt in the user's language. */
@Composable
fun localizedRationale(sel: ModelSelection): String = stringResource(
    R.string.fitness_rationale,
    sel.model.label,
    sel.device.deviceName,
    f0(sel.estimatedTokensPerSecond),
    sel.device.soc.displayName,
    localizedSpeedWord(sel.estimatedTokensPerSecond),
    f1(sel.estimatedRuntimeGb),
    f1(sel.appMemoryBudgetGb),
    f1(sel.memoryHeadroomGb),
)

/** "Light for chat — a typical reply costs ~X% battery…", localized. */
@Composable
fun localizedChatVerdict(sel: ModelSelection): String {
    val reply = sel.thermalBattery.replyPercent
    val replyStr = if (reply < 0.1) "0.1" else f1(reply)
    return stringResource(R.string.fitness_chat_verdict, replyStr)
}

/** "Sustained / agent use: warms and throttles ~X% slower…", localized. */
@Composable
fun localizedSustainedVerdict(sel: ModelSelection): String = stringResource(
    R.string.fitness_sustained_verdict,
    f0(sel.thermalBattery.throttledLossPercent),
    f0(sel.thermalBattery.activeDrainPercentPerHour),
)
