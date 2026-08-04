package ai.quenderin.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.quenderin.app.R
import kotlinx.coroutines.delay
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Engagement surface while a multi-GB model downloads: sticky progress, rotating tips,
 * and a casual “catch the tokens” mini-game so first-run wait is not a dead screen.
 * Twin of iOS `DownloadWaitPlayground`.
 */
@Composable
fun DownloadWaitPlayground(
    modelLabel: String,
    sizeLabel: String,
    fraction: Float,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pct = (fraction * 100f).toInt().coerceIn(0, 100)
    val tips = remember {
        listOf(
            R.string.wait_tip_1,
            R.string.wait_tip_2,
            R.string.wait_tip_3,
            R.string.wait_tip_4,
            R.string.wait_tip_5,
            R.string.wait_tip_6,
            R.string.wait_tip_7,
            R.string.wait_tip_8,
        )
    }
    var tipIndex by remember { mutableIntStateOf(0) }
    // (elapsedMs, fraction) samples for ETA
    val etaSamples = remember { mutableStateListOf<Pair<Long, Float>>() }
    var etaLabel by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(6_000)
            tipIndex = (tipIndex + 1) % tips.size
        }
    }
    LaunchedEffect(fraction) {
        val now = System.currentTimeMillis()
        etaSamples.add(now to fraction)
        while (etaSamples.isNotEmpty() && now - etaSamples.first().first > 30_000) {
            etaSamples.removeAt(0)
        }
        etaLabel = estimateEta(etaSamples.toList(), fraction)
    }

    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(scheme.surfaceVariant.copy(alpha = 0.55f))
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.wait_downloading_pct, pct),
                    style = MaterialTheme.typography.labelLarge.copy(
                        fontWeight = FontWeight.SemiBold,
                        fontFeatureSettings = "tnum",
                    ),
                )
                etaLabel?.let { eta ->
                    Text(
                        eta,
                        style = MaterialTheme.typography.labelSmall.copy(fontFeatureSettings = "tnum"),
                        color = scheme.onSurfaceVariant,
                    )
                }
            }
            Text(
                "$modelLabel · $sizeLabel",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                maxLines = 1,
            )
            val a11y = stringResource(R.string.onboarding_downloading_a11y, modelLabel, pct)
            LinearProgressIndicator(
                progress = { fraction.coerceIn(0f, 1f) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .semantics {
                        progressBarRangeInfo = ProgressBarRangeInfo(fraction, 0f..1f)
                        stateDescription = a11y
                    },
                color = scheme.primary,
                trackColor = scheme.onSurfaceVariant.copy(alpha = 0.15f),
                strokeCap = StrokeCap.Round,
            )
            Text(
                stringResource(R.string.wait_one_time_play),
                style = MaterialTheme.typography.labelSmall,
                color = scheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Text(
            stringResource(tips[tipIndex]),
            style = MaterialTheme.typography.bodySmall,
            color = scheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 4.dp)
                .semantics { contentDescription = "While you wait" },
        )

        var score by remember { mutableIntStateOf(0) }
        var highScore by remember { mutableIntStateOf(0) }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.wait_catch_title),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                stringResource(R.string.wait_score, score),
                style = MaterialTheme.typography.labelLarge.copy(
                    fontWeight = FontWeight.SemiBold,
                    fontFeatureSettings = "tnum",
                ),
                color = scheme.primary,
            )
        }

        TokenCatchField(
            primary = scheme.primary,
            surfaceVariant = scheme.surfaceVariant,
            onSurfaceVariant = scheme.onSurfaceVariant,
            onScore = { s ->
                score = s
                if (s > highScore) highScore = s
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(168.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(scheme.surfaceVariant.copy(alpha = 0.35f)),
        )

        if (highScore > 0) {
            Text(
                stringResource(R.string.wait_best, highScore),
                style = MaterialTheme.typography.labelSmall.copy(fontFeatureSettings = "tnum"),
                color = scheme.onSurfaceVariant,
            )
        }

        TextButton(onClick = onCancel) {
            Text(stringResource(R.string.wait_cancel_download))
        }
    }
}

/** Remaining-time label from (timestampMs, fraction) samples — twin of iOS DownloadETA. */
internal fun estimateEta(samples: List<Pair<Long, Float>>, progress: Float): String? {
    if (progress <= 0.02f || progress >= 0.99f || samples.size < 2) return null
    val first = samples.first()
    val last = samples.last()
    val dtSec = (last.first - first.first) / 1000.0
    val dp = (last.second - first.second).toDouble()
    if (dtSec < 2.0 || dp <= 0.005) return null
    val rate = dp / dtSec
    val remaining = (1.0 - progress) / rate
    if (!remaining.isFinite() || remaining <= 0 || remaining >= 6 * 3600) return null
    return when {
        remaining < 60 -> "~${maxOf(1, remaining.toInt())}s left"
        remaining < 3600 -> "~${maxOf(1, (remaining / 60).toInt())} min left"
        else -> String.format("~%.1f h left", remaining / 3600.0)
    }
}

private data class FallingToken(val id: Int, var x: Float, var y: Float, val speed: Float)

@Composable
private fun TokenCatchField(
    primary: Color,
    surfaceVariant: Color,
    onSurfaceVariant: Color,
    onScore: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = remember { mutableStateListOf<FallingToken>() }
    var nextId by remember { mutableIntStateOf(1) }
    var spawnAccum by remember { mutableFloatStateOf(0f) }
    var score by remember { mutableIntStateOf(0) }
    var widthPx by remember { mutableFloatStateOf(1f) }
    var heightPx by remember { mutableFloatStateOf(1f) }

    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (last == 0L) {
                    last = now
                    return@withFrameNanos
                }
                val dt = ((now - last) / 1_000_000_000f).coerceIn(0f, 0.05f)
                last = now
                // Fall
                val iter = tokens.listIterator()
                while (iter.hasNext()) {
                    val t = iter.next()
                    t.y += t.speed * dt
                    if (t.y > 1.12f) iter.remove()
                }
                spawnAccum += dt * 1.35f
                while (spawnAccum >= 1f) {
                    spawnAccum -= 1f
                    val h = Random.nextFloat()
                    tokens.add(
                        FallingToken(
                            id = nextId++,
                            x = 0.08f + h * 0.84f,
                            y = -0.06f,
                            speed = 0.18f + h * 0.28f,
                        ),
                    )
                }
            }
        }
    }

    val emptyHint = stringResource(R.string.wait_tap_hint)
    Box(
        modifier = modifier
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    val nx = offset.x / size.width
                    val ny = offset.y / size.height
                    val radius = 0.09f
                    val hit = tokens.indexOfFirst { t ->
                        val dx = t.x - nx
                        val dy = t.y - ny
                        sqrt(dx * dx + dy * dy) <= radius
                    }
                    if (hit >= 0) {
                        tokens.removeAt(hit)
                        score += 1
                        onScore(score)
                    }
                }
            }
            .semantics {
                contentDescription = "Token catch game. Tap glowing tokens as they fall."
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            widthPx = size.width
            heightPx = size.height
            for (t in tokens) {
                val r = minOf(size.width, size.height) * 0.055f
                val c = Offset(t.x * size.width, t.y * size.height)
                drawCircle(color = primary.copy(alpha = 0.2f), radius = r * 1.6f, center = c)
                drawCircle(color = primary, radius = r, center = c)
            }
        }
        if (tokens.isEmpty() && score == 0) {
            Text(
                emptyHint,
                style = MaterialTheme.typography.labelMedium,
                color = onSurfaceVariant,
                modifier = Modifier.align(Alignment.Center),
            )
        }
    }
}
