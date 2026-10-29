package ai.quenderin.app

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File

/** Nine selected synthetic frames plus one last-failure frame; no general file capture API. */
internal object ScreenshotEvidence {
    private val names = setOf(
        "01-welcome-light.png", "02-setup-light.png", "03-chat-light.png",
        "04-report-light.png", "05-chat-dark-keyboard.png", "06-setup-large-text.png",
        "07-settings-short-window.png", "09-bot-roster.png", "10-bot-history.png", "08-failure.png",
    )

    @OptIn(ExperimentalTestApi::class)
    fun capture(name: String, renderedNode: SemanticsNodeInteraction? = null) {
        require(name in names)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // Semantics/accessibility idle does not establish a new rendered window buffer.
        // BOM 2024.09.03 pins ui-test 1.7.3: captureToImage -> forceRedraw (frame commit)
        // -> PixelCopy completion. Exact release source:
        // https://github.com/androidx/androidx/blob/00e91ed140ce2c4677f56fc06692b182b8a07fcf/compose/ui/ui-test/src/androidMain/kotlin/androidx/compose/ui/test/android/WindowCapture.android.kt
        // Discard that cropped image, then capture the full display so IME, dialogs and
        // system bars remain genuine parts of the evidence. Failure frames are best effort.
        renderedNode?.captureToImage()?.asAndroidBitmap()?.recycle()
        val original = checkNotNull(instrumentation.uiAutomation.takeScreenshot()) { "Screenshot unavailable" }
        var image = original
        var limit = 1280
        try {
            var encoded: ByteArray
            while (true) {
                val scale = minOf(1f, limit.toFloat() / maxOf(original.width, original.height))
                if (image !== original) image.recycle()
                image = if (scale < 1f) Bitmap.createScaledBitmap(original,
                    (original.width * scale).toInt().coerceAtLeast(1),
                    (original.height * scale).toInt().coerceAtLeast(1), true) else original
                encoded = ByteArrayOutputStream().use { output ->
                    check(image.compress(Bitmap.CompressFormat.PNG, 100, output))
                    output.toByteArray()
                }
                if (encoded.size <= 1024 * 1024) break
                check(limit > 640) { "Screenshot exceeds the 1 MiB bound" }
                limit = (limit * 0.8f).toInt().coerceAtLeast(640)
            }
            val directory = File(instrumentation.targetContext.cacheDir, "ui-journeys")
                .apply { check(mkdirs() || isDirectory) }
            File(directory, name).writeBytes(encoded)
            println("UI_SCREENSHOT_SAVED $name ${image.width}x${image.height} bytes=${encoded.size} original=${original.width}x${original.height}")
        } finally {
            if (image !== original) image.recycle()
            original.recycle()
        }
    }
}
