package ai.quenderin.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Brand purple shared with the desktop app + marketing site.
private val Brand = Color(0xFF635BFF)
private val BrandLight = Color(0xFF8B83FF)

private val LightColors = lightColorScheme(primary = Brand)
private val DarkColors = darkColorScheme(primary = BrandLight)

@Composable
fun QuenderinTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        content = content,
    )
}
