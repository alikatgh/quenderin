package ai.quenderin.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import android.app.Activity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat

// ── Brand ────────────────────────────────────────────────────────────────────
// Derived from the brand artwork (brand/icon-square-1024.png), shared with iOS + the site:
// teal = her braids/eyes/choker, copper = the "Q" and warm braid strands. Sampled 2026-07-03;
// change the art → resample, don't guess. Twin of iOS QuenderinPalette.
private val Brand = Color(0xFF2E7680)         // teal (light-theme primary)
private val BrandBright = Color(0xFF52939A)   // teal (dark-theme primary)

// ── Dark palette (the primary experience — a private, focused, "at night" feel) ──
private val DarkScheme = darkColorScheme(
    primary = BrandBright,
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF1C4E5D),
    onPrimaryContainer = Color(0xFFE2F2F1),
    secondary = Color(0xFF37C98B),           // the "on-device · private" status accent
    onSecondary = Color(0xFF04150E),
    secondaryContainer = Color(0xFF244249),   // selected bottom-tab pill (teal-tinted, on-brand)
    onSecondaryContainer = Color(0xFFCDEBEE), // its icon — ~8:1 on the pill (was primary ≈2.65:1)
    background = Color(0xFF0B0F10),           // chat canvas
    onBackground = Color(0xFFE8EDEA),
    surface = Color(0xFF141A1B),             // top bar, sheets
    onSurface = Color(0xFFE8EDEA),
    surfaceVariant = Color(0xFF1C2426),       // assistant bubble, input pill, cards
    onSurfaceVariant = Color(0xFF93A19E),     // muted labels
    // Warm teal-charcoal surface ladder — set so NOTHING falls back to M3's cool-grey baseline
    // (bottom bar, dropdown menus, sheets, dialogs all read from this family).
    surfaceContainerLowest = Color(0xFF070B0C),
    surfaceContainerLow = Color(0xFF101618),
    surfaceContainer = Color(0xFF151B1C),     // bottom nav bar
    surfaceContainerHigh = Color(0xFF1F2627), // menus, dialogs
    surfaceContainerHighest = Color(0xFF29302F),
    surfaceBright = Color(0xFF31383A),
    surfaceDim = Color(0xFF0B0F10),
    inverseSurface = Color(0xFFE8EDEA),
    inverseOnSurface = Color(0xFF1C2224),
    inversePrimary = Brand,
    tertiary = Color(0xFFD8B48C),             // brand copper (the "Q") — never M3's baseline purple
    onTertiary = Color(0xFF35240F),
    tertiaryContainer = Color(0xFF52402C),
    onTertiaryContainer = Color(0xFFF3E4D2),
    outline = Color(0xFF31403E),
    outlineVariant = Color(0xFF232E2D),       // hairlines
    error = Color(0xFFF2919B),
    onError = Color(0xFF3A0A11),
)

// ── Light palette (mirrors the dark roles; kept clean + airy) ──
private val LightScheme = lightColorScheme(
    primary = Brand,
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD7EAEA),
    onPrimaryContainer = Color(0xFF123A40),
    secondary = Color(0xFF0E9E6B),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFCFE7E6),   // selected bottom-tab pill (teal-tinted, on-brand)
    onSecondaryContainer = Color(0xFF123A40), // its icon — high contrast on the pill
    background = Color(0xFFF5F4EF),
    onBackground = Color(0xFF1C2224),
    surface = Color(0xFFFBFAF5),             // sheets/dialogs — warm off-white, not cold #FFF
    onSurface = Color(0xFF1C2224),
    surfaceVariant = Color(0xFFE9E7DE),       // assistant bubble on light
    onSurfaceVariant = Color(0xFF5D6B68),
    // Warm cream surface ladder — set so NOTHING falls back to M3's cool-lavender baseline
    // (bottom bar, dropdown menus, sheets, dialogs all read from this family).
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFFAF9F4),
    surfaceContainer = Color(0xFFF0EEE6),     // bottom nav bar
    surfaceContainerHigh = Color(0xFFEBE9E0), // menus, dialogs
    surfaceContainerHighest = Color(0xFFE5E3D9),
    surfaceBright = Color(0xFFFBFAF5),
    surfaceDim = Color(0xFFE2E0D6),
    inverseSurface = Color(0xFF31302B),
    inverseOnSurface = Color(0xFFF3F1E9),
    inversePrimary = BrandBright,
    tertiary = Color(0xFF8A6A44),             // brand copper (the "Q") — never M3's baseline purple
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFF3E4D2),
    onTertiaryContainer = Color(0xFF34240F),
    outline = Color(0xFFC3CCC8),
    outlineVariant = Color(0xFFE0E3DC),
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
    userBubble = Color(0xFF245A62),
    onUserBubble = Color(0xFFEAF6F4),
    userTimestamp = Color(0xFFA8CDD1),
    assistantBubble = Color(0xFF1C2426),
    onAssistantBubble = Color(0xFFE8EDEA),
    assistantTimestamp = Color(0xFF798682),
    status = Color(0xFF37C98B),
    statusText = Color(0xFF8FE8C4),
    dayDivider = Color(0xFF171E1F),
    onDayDivider = Color(0xFF8C9996),
)

private val LightQuenderinColors = QuenderinColors(
    userBubble = Color(0xFF2E7680),
    onUserBubble = Color(0xFFFFFFFF),
    userTimestamp = Color(0xFFC9E4E6),
    assistantBubble = Color(0xFFFFFFFF),
    onAssistantBubble = Color(0xFF1C2224),
    assistantTimestamp = Color(0xFF97A4A1),
    status = Color(0xFF0E9E6B),
    statusText = Color(0xFF0B7E57),
    dayDivider = Color(0xFFE7E5DC),
    onDayDivider = Color(0xFF77837F),
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
    val view = LocalView.current
    if (!view.isInEditMode) {
        // The app is edge-to-edge (targetSdk 35), so the system status/nav bar icons draw over the
        // app background — they MUST contrast it: dark icons on the light cream theme (they were
        // white → invisible), light icons on the dark theme. Reacts to theme changes via SideEffect.
        SideEffect {
            val window = (view.context as Activity).window
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    CompositionLocalProvider(
        LocalQuenderinColors provides if (dark) DarkQuenderinColors else LightQuenderinColors,
    ) {
        MaterialTheme(
            colorScheme = if (dark) DarkScheme else LightScheme,
            content = content,
        )
    }
}
