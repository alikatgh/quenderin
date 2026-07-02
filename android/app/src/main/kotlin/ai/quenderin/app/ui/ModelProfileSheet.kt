package ai.quenderin.app.ui

import ai.quenderin.core.ModelEntry
import ai.quenderin.core.Quantization
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * The model "profile" — tapping the chat header opens this. A scrollable page of everything the app
 * knows about the active model (params, quantization, precision, size, memory, provenance) plus the
 * per-model behaviour toggle (Deep thinking) and a shortcut to switch models. Read-only info +
 * two actions, so it stays a bottom sheet rather than a whole navigation destination.
 */
@Composable
internal fun ModelProfileSheet(
    model: ModelEntry,
    deepThinking: Boolean,
    onDeepThinkingChange: (Boolean) -> Unit,
    onChangeModel: () -> Unit,
) {
    val context = LocalContext.current
    val quant = Quantization.info(model.quantization)
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        // ── Identity header ──
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            ModelAvatar(size = 72.dp)
            Spacer(Modifier.height(12.dp))
            Text(
                model.label,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            StatusChip()
            Spacer(Modifier.height(10.dp))
            Text(
                modelBlurb(model.id),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }

        ProfileCard("Specifications") {
            SpecRow("Parameters", "${fmt(model.paramsBillions)}B")
            SpecRow("Download size", model.sizeLabel.removeSuffix(" download"))
            SpecRow("Memory needed", "~${fmt(model.ramGB)} GB RAM")
            SpecRow("Quantization", model.quantization)
            if (quant != null) {
                SpecRow("Precision", "${fmt(quant.bitsPerWeight)} bits/weight")
                SpecRow("Quality", quant.quality)
            }
            SpecRow("Format", "GGUF")
        }

        ProfileCard("Reasoning") {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Deep thinking", color = MaterialTheme.colorScheme.onSurface)
                    Caption(
                        if (deepThinking) "The model reasons step-by-step before answering — better on hard " +
                            "questions, but noticeably slower."
                        else "Off: fast, direct answers. Turn on to let the model reason step-by-step (slower).",
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = deepThinking, onCheckedChange = onDeepThinkingChange)
            }
        }

        ProfileCard("Privacy") {
            Caption(
                "Runs entirely on-device via llama.cpp. No account, no cloud, no tracking — once " +
                    "downloaded it works fully offline and nothing you type leaves your phone.",
            )
        }

        ProfileCard("Technical") {
            SpecRow("File", model.filename)
            LinkRow("Source") {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(model.url))) }
            }
            SpecRow("Checksum", model.sha256?.let { "${it.take(12)}…" } ?: "magic-only")
        }

        OutlinedButton(onClick = onChangeModel, modifier = Modifier.fillMaxWidth()) {
            Text("Change model…")
        }
    }
}

/** Green presence dot + "on-device · private", matching the chat top bar. */
@Composable
private fun StatusChip() {
    val colors = Quenderin.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).background(colors.status, CircleShape))
        Spacer(Modifier.width(6.dp))
        Text("on-device · private", style = MaterialTheme.typography.labelMedium, color = colors.statusText)
    }
}

/** A titled card (small primary label above a rounded surface holding the rows). */
@Composable
private fun ProfileCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 4.dp, bottom = 8.dp),
        )
        Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = QuenderinShapes.card, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        }
    }
}

/** Label on the left, value on the right (the value wraps/ellipsizes rather than pushing the label off). */
@Composable
private fun SpecRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = MaterialTheme.colorScheme.onSurface)
        Spacer(Modifier.width(16.dp))
        Text(
            value,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.End,
            modifier = Modifier.weight(1f, fill = false),
        )
    }
}

/** A row whose right side is a tappable "Hugging Face ↗" link (the model's source URL). */
@Composable
private fun LinkRow(label: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 24.dp).clickable(onClickLabel = "Open source page") { onClick() },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurface)
        Text("Hugging Face ↗", color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Drops a trailing ".0" so "4.0" reads "4" but "3.8" stays "3.8". */
private fun fmt(d: Double): String = if (d % 1.0 == 0.0) d.toInt().toString() else d.toString()

/** One-line, family-specific description keyed off the catalog id. Purely cosmetic copy. */
private fun modelBlurb(id: String): String = when {
    id.startsWith("qwen3") -> "Alibaba's Qwen3 — a strong, broadly multilingual all-rounder."
    id.startsWith("qwen25-coder") -> "Qwen2.5 Coder — tuned for programming and code reasoning."
    id.startsWith("deepseek-r1") -> "DeepSeek-R1 distilled — a reasoning-focused model that thinks before it answers."
    id.startsWith("mistral") -> "Mistral — a fast, well-balanced general-purpose model."
    id.startsWith("gemma3") -> "Google's Gemma 3 — strong multilingual coverage for its size."
    id.startsWith("phi4") -> "Microsoft's Phi-4 Mini — efficient and capable for its footprint."
    id.startsWith("llama") -> "Meta's Llama — a capable, general-purpose instruct model."
    else -> "An on-device language model running locally via llama.cpp."
}
