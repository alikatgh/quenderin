package ai.quenderin.app.ui

import androidx.compose.ui.res.stringResource
import ai.quenderin.app.R

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

        ProfileCard(stringResource(R.string.profile_specifications)) {
            SpecRow(stringResource(R.string.profile_parameters), stringResource(R.string.profile_params_value, fmt(model.paramsBillions)))
            SpecRow(stringResource(R.string.profile_download_size), model.sizeLabel.removeSuffix(" download"))
            SpecRow(stringResource(R.string.profile_memory_needed), stringResource(R.string.profile_memory_value, fmt(model.ramGB)))
            SpecRow(stringResource(R.string.profile_quantization), model.quantization)
            if (quant != null) {
                SpecRow(stringResource(R.string.profile_precision), stringResource(R.string.profile_precision_bits, fmt(quant.bitsPerWeight)))
                SpecRow(stringResource(R.string.profile_quality), quant.quality)
            }
            SpecRow(stringResource(R.string.profile_format), "GGUF")
        }

        ProfileCard(stringResource(R.string.profile_reasoning)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.model_deep_thinking), color = MaterialTheme.colorScheme.onSurface)
                    Caption(stringResource(if (deepThinking) R.string.profile_reasoning_on else R.string.profile_reasoning_off))
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = deepThinking, onCheckedChange = onDeepThinkingChange)
            }
        }

        ProfileCard(stringResource(R.string.profile_privacy)) {
            Caption(stringResource(R.string.profile_privacy_body))
        }

        ProfileCard(stringResource(R.string.profile_technical)) {
            SpecRow(stringResource(R.string.profile_file), model.filename)
            LinkRow(stringResource(R.string.profile_source)) {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(model.url))) }
            }
            SpecRow(stringResource(R.string.profile_checksum), model.sha256?.let { "${it.take(12)}…" } ?: stringResource(R.string.profile_checksum_magic))
        }

        OutlinedButton(onClick = onChangeModel, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.model_change))
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
        Text(stringResource(R.string.badge_on_device_private), style = MaterialTheme.typography.labelMedium, color = colors.statusText)
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
        Modifier.fillMaxWidth().heightIn(min = 24.dp).clickable(onClickLabel = stringResource(R.string.profile_open_source_page)) { onClick() },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurface)
        Text(stringResource(R.string.link_hugging_face), color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Drops a trailing ".0" so "4.0" reads "4" but "3.8" stays "3.8". */
private fun fmt(d: Double): String = if (d % 1.0 == 0.0) d.toInt().toString() else d.toString()

/** One-line, family-specific description keyed off the catalog id. Purely cosmetic copy. */
@Composable
internal fun modelBlurb(id: String): String = stringResource(
    when {
        id.startsWith("qwen3") -> R.string.blurb_qwen3
        id.startsWith("qwen25-coder") -> R.string.blurb_qwen25_coder
        id.startsWith("deepseek-r1") -> R.string.blurb_deepseek_r1
        id.startsWith("mistral") -> R.string.blurb_mistral
        id.startsWith("gemma4") -> R.string.blurb_gemma4
        id.startsWith("gemma3") -> R.string.blurb_gemma3
        id.startsWith("phi4") -> R.string.blurb_phi4
        id.startsWith("llama") -> R.string.blurb_llama
        else -> R.string.blurb_generic
    }
)
