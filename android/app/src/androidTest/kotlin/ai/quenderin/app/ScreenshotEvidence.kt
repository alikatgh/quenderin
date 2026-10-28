package ai.quenderin.app

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File

/** Seven selected synthetic frames plus one last-failure frame; no general file capture API. */
internal object ScreenshotEvidence {
    private val names = setOf(
        "01-welcome-light.png", "02-setup-light.png", "03-chat-light.png",
        "04-report-light.png", "05-chat-dark-keyboard.png", "06-setup-large-text.png",
        "07-settings-short-window.png", "08-failure.png",
    )

    fun capture(name: String) {
        require(name in names)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // Compose semantics can update before platform window events settle.
        // Wait for an idle accessibility event stream within a fixed deadline;
        // the exported frames still require visual inspection against their names.
        instrumentation.uiAutomation.waitForIdle(250L, 3_000L)
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
