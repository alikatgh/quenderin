package ai.quenderin.app.ui

import ai.quenderin.app.R
import androidx.compose.ui.res.stringResource
import ai.quenderin.core.MemoryCheckResult
import ai.quenderin.core.MemoryFitness
import ai.quenderin.core.MemorySeverity
import ai.quenderin.core.ModelCatalog
import ai.quenderin.core.ModelEntry
import ai.quenderin.core.ModelRecommender
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** Same warn orange as OnboardingScreen's StorageShortfallCard — the "tight / blocked" accent. */
private val Warn = Color(0xFFE8963A)

/**
 * Pick a different model: the catalog grouped so the first screenful is things you can actually
 * tap — the device's recommendation on top (brand hairline), then every other model that fits,
 * and only at the bottom the ones that don't, each dimmed with a structured "not enough memory"
 * card (dot + headline + the two numbers). Rows carry the design-system anatomy: name +
 * capability chip · family blurb · monospaced size/quant/RAM meta · explicit fit badge
 * ("Fits" / "Tight" / "Too big"). Twin of the Apple `ModelPickerView`; shared by Settings,
 * the chat model-profile sheet, and onboarding, so the picker exists once.
 */
@Composable
internal fun ModelPickerSheet(currentModelId: String, onSelect: (ModelEntry) -> Unit) {
    val context = LocalContext.current
    // Same memory gate as onboarding — the sheet must never offer a model this phone can't load.
    val (totalGb, freeGb) = remember {
        val am = context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val mi = android.app.ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val gb = 1_073_741_824.0
        (mi.totalMem / gb) to (mi.availMem / gb)
    }
    val options = remember {
        ModelCatalog.models.map { it to MemoryFitness.check(it, totalGb, freeGb) }
    }
    // Fitness-aware: the tag must sit on a row this same sheet can actually install, never on
    // one it dims and disables (band-vs-budget disagreement, e.g. 14B on 16 GB).
    val recommendedId = remember { ModelRecommender.bestInstallableModel(totalGb, freeGb).id }

    val recommended = options.filter { it.first.id == recommendedId }
    val fitting = options.filter { it.first.id != recommendedId && it.second.canLoad }
    val blocked = options.filter { it.first.id != recommendedId && !it.second.canLoad }

    Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        Text(
            "Choose a model",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 4.dp),
        )
        Text(
            "All of these run fully on your phone — a one-time download, then it's yours offline.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        )
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = 480.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (recommended.isNotEmpty()) {
                SectionHeader("Recommended for this phone", MaterialTheme.colorScheme.primary)
                recommended.forEach { (entry, fitness) ->
                    ModelPickerRow(entry, fitness, isRecommended = true, isCurrent = entry.id == currentModelId) { onSelect(entry) }
                }
            }
            if (fitting.isNotEmpty()) {
                SectionHeader("All models", MaterialTheme.colorScheme.onSurfaceVariant)
                fitting.forEach { (entry, fitness) ->
                    ModelPickerRow(entry, fitness, isRecommended = false, isCurrent = entry.id == currentModelId) { onSelect(entry) }
                }
            }
            if (blocked.isNotEmpty()) {
                // Ineligible models sink to the BOTTOM: the sheet opens on choices, not warnings.
                SectionHeader("Too big for this phone", MaterialTheme.colorScheme.onSurfaceVariant)
                blocked.forEach { (entry, fitness) ->
                    ModelPickerRow(entry, fitness, isRecommended = false, isCurrent = entry.id == currentModelId) { onSelect(entry) }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String, color: Color) {
    Text(
        title.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
        modifier = Modifier.padding(top = 6.dp).semantics { heading() },
    )
}

@Composable
private fun ModelPickerRow(
    entry: ModelEntry,
    fitness: MemoryCheckResult,
    isRecommended: Boolean,
    isCurrent: Boolean,
    onClick: () -> Unit,
) {
    val enabled = fitness.canLoad && !isCurrent
    val (name, tag) = splitLabel(entry.label)
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = QuenderinShapes.card,
        // Hairline border; brand-tinted on the recommended card (color changes, never geometry).
        border = BorderStroke(
            1.dp,
            if (isRecommended) MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)
            else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = Modifier.fillMaxWidth().alpha(if (fitness.canLoad) 1f else 0.45f),
    ) {
        Column(
            Modifier
                .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        name,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (tag != null) {
                        Text(
                            tag,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            modifier = Modifier
                                .border(1.dp, MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f), QuenderinShapes.pill)
                                .padding(horizontal = 6.dp, vertical = 1.dp),
                        )
                    }
                }
                Spacer(Modifier.width(10.dp))
                if (isCurrent) {
                    // The model you're already running — status-green, same dot+word language.
                    DotBadge(Quenderin.colors.status, "Current", Quenderin.colors.statusText)
                } else {
                    FitBadge(fitness)
                }
            }
            Text(
                modelBlurb(entry.id),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                stringResource(R.string.picker_model_meta, entry.sizeLabel.removeSuffix(" download"), entry.quantization, fmt1(entry.ramGB)),
                style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!fitness.canLoad) MemoryShortfallNote(fitness)
        }
    }
}

/**
 * The explicit fit verdict — a status dot + word, the same visual language as the chat header's
 * "on-device · private". Green "Fits", orange "Tight", red "Too big".
 */
@Composable
private fun FitBadge(fitness: MemoryCheckResult) {
    when {
        !fitness.canLoad -> DotBadge(MaterialTheme.colorScheme.error, stringResource(R.string.fit_too_big), MaterialTheme.colorScheme.error)
        fitness.severity == MemorySeverity.SAFE -> DotBadge(Quenderin.colors.status, stringResource(R.string.fit_fits), Quenderin.colors.statusText)
        else -> DotBadge(Warn, stringResource(R.string.fit_tight), Warn)
    }
}

@Composable
private fun DotBadge(dot: Color, text: String, textColor: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).background(dot, CircleShape))
        Spacer(Modifier.width(5.dp))
        Text(text, style = MaterialTheme.typography.labelMedium, color = textColor)
    }
}

/**
 * Why a model can't load, as a compact structured card — orange dot + short headline + ONE
 * plain-toned sentence carrying the two numbers the memory check actually used. The same visual
 * language as onboarding's `StorageShortfallCard`, never a wall of colored text.
 */
@Composable
private fun MemoryShortfallNote(fitness: MemoryCheckResult) {
    Surface(color = Warn.copy(alpha = 0.10f), shape = RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).background(Warn, CircleShape))
                Spacer(Modifier.width(6.dp))
                Text(
                    stringResource(R.string.picker_not_enough_memory),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            Text(
                stringResource(R.string.picker_memory_shortfall, fmt1(fitness.requiredGB), fmt1(fitness.availableGB)),
                style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * "Qwen3 14B (Best Quality)" → name "Qwen3 14B" + capability chip "Best Quality" — the
 * parenthetical reads better as a quiet tag than as half the headline.
 */
private fun splitLabel(label: String): Pair<String, String?> {
    val open = label.indexOf(" (")
    if (open < 0 || !label.endsWith(")")) return label to null
    return label.substring(0, open) to label.substring(open + 2, label.length - 1)
}

private fun fmt1(v: Double): String = String.format("%.1f", v)
