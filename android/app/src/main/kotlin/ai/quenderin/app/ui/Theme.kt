package ai.quenderin.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp

// ── Brand ────────────────────────────────────────────────────────────────────
// Indigo shared with the desktop app + marketing site. The whole UI is tuned around it.
private val Brand = Color(0xFF635BFF)
private val BrandBright = Color(0xFF8B83FF)

// ── Dark palette (the primary experience — a private, focused, "at night" feel) ──
private val DarkScheme = darkColorScheme(
    primary = BrandBright,
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF4F46B8),
    onPrimaryContainer = Color(0xFFECEAFB),
    secondary = Color(0xFF37C98B),           // the "on-device · private" status accent
    onSecondary = Color(0xFF04150E),
    background = Color(0xFF0B0B10),           // chat canvas
    onBackground = Color(0xFFECEAF6),
    surface = Color(0xFF16161D),             // top bar, sheets
    onSurface = Color(0xFFE9E7F2),
    surfaceVariant = Color(0xFF1E1E27),       // assistant bubble, input pill, cards
    onSurfaceVariant = Color(0xFF9C99AE),     // muted labels
    outline = Color(0xFF34343F),
    outlineVariant = Color(0xFF26262F),       // hairlines
    error = Color(0xFFF2919B),
    onError = Color(0xFF3A0A11),
)

// ── Light palette (mirrors the dark roles; kept clean + airy) ──
private val LightScheme = lightColorScheme(
    primary = Brand,
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE6E4FF),
    onPrimaryContainer = Color(0xFF1E1A5C),
    secondary = Color(0xFF0E9E6B),
    onSecondary = Color(0xFFFFFFFF),
    background = Color(0xFFF6F5FB),
    onBackground = Color(0xFF1A1A22),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1A1A22),
    surfaceVariant = Color(0xFFEDEBF5),       // assistant bubble on light
    onSurfaceVariant = Color(0xFF66647A),
    outline = Color(0xFFC9C7D6),
    outlineVariant = Color(0xFFE4E2EE),
    error = Color(0xFFB3261E),
    onError = Color(0xFFFFFFFF),
)

/**
 * App-specific design tokens Material's ColorScheme doesn't model — chat bubble colors, the live
 * status accent, and the asymmetric bubble shapes (the flat corner is the "tail" toward the speaker).
 * Exposed through [LocalQuenderinColors] so every screen reads ONE source of truth. Twin of the iOS
 * `Theme` tokens.
 */
data class QuenderinColors(
    val userBubble: Color,
    val onUserBubble: Color,
    val userTimestamp: Color,
    val assistantBubble: Color,
    val onAssistantBubble: Color,
    val assistantTimestamp: Color,
    val status: Color,          // the green presence dot
    val statusText: Color,
    val dayDivider: Color,
    val onDayDivider: Color,
)

private val DarkQuenderinColors = QuenderinColors(
    userBubble = Color(0xFF5D54C4),
    onUserBubble = Color(0xFFF4F2FF),
    userTimestamp = Color(0xFFC4BFF0),
    assistantBubble = Color(0xFF1E1E27),
    onAssistantBubble = Color(0xFFE9E7F2),
    assistantTimestamp = Color(0xFF78758A),
    status = Color(0xFF37C98B),
    statusText = Color(0xFF8FE8C4),
    dayDivider = Color(0xFF1B1B23),
    onDayDivider = Color(0xFF8B889C),
)

private val LightQuenderinColors = QuenderinColors(
    userBubble = Color(0xFF635BFF),
    onUserBubble = Color(0xFFFFFFFF),
    userTimestamp = Color(0xFFDAD7FA),
    assistantBubble = Color(0xFFFFFFFF),
    onAssistantBubble = Color(0xFF1A1A22),
    assistantTimestamp = Color(0xFF9A98AC),
    status = Color(0xFF0E9E6B),
    statusText = Color(0xFF0E7E56),
    dayDivider = Color(0xFFE9E7F2),
    onDayDivider = Color(0xFF7A7889),
)

val LocalQuenderinColors = staticCompositionLocalOf { DarkQuenderinColors }

/** Bubble corner shapes: 18dp everywhere except the "tail" corner (4dp) toward the speaker. */
object QuenderinShapes {
    val userBubble: Shape = RoundedCornerShape(18.dp, 18.dp, 4.dp, 18.dp)
    val assistantBubble: Shape = RoundedCornerShape(18.dp, 18.dp, 18.dp, 4.dp)
    val card: Shape = RoundedCornerShape(16.dp)
    val pill: Shape = RoundedCornerShape(24.dp)
}

/** Ergonomic accessor: `Quenderin.colors.userBubble` from any composable. */
object Quenderin {
    val colors: QuenderinColors
        @Composable get() = LocalQuenderinColors.current
}

@Composable
fun QuenderinTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    CompositionLocalProvider(
        LocalQuenderinColors provides if (dark) DarkQuenderinColors else LightQuenderinColors,
    ) {
        MaterialTheme(
            colorScheme = if (dark) DarkScheme else LightScheme,
            content = content,
        )
    }
}
