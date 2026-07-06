package ai.quenderin.core

/**
 * The download seam for fetching a GGUF "module" onto the device. The real Android
 * implementation lives in the app module (WorkManager + a resumable foreground
 * download with a Wi-Fi/disk-space preflight); the core only depends on this seam so
 * the onboarding flow tests on the JVM. Twin of Swift `ModelDownloader`.
 */
interface ModelDownloader {
    /**
     * Downloads [model], reporting fractional progress in 0.0..1.0, and returns the
     * absolute local file path of the finished GGUF. Throws on failure.
     */
    fun download(model: ModelEntry, onProgress: (Double) -> Unit): String

    /**
     * True when [download] would actually need the network for [model] — i.e. there is NO
     * integrity-verified file already at the destination. Lets the caller run its download-only
     * preflights (disk space, cellular policy) ONLY when a fetch is real, so a model already on
     * disk is never spuriously Wi-Fi-blocked (twin of the Swift install() `if !fileExists` block).
     * Default true (assume a fetch is needed) fails safe — the gates run — and keeps mocks unchanged.
     */
    fun needsFetch(model: ModelEntry): Boolean = true
}

/** Canned downloader for previews, tests, and bringing up the app before the real one. */
class MockModelDownloader(
    private val destinationPath: String = "/tmp/quenderin/mock.gguf",
) : ModelDownloader {
    override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String {
        for (frac in listOf(0.25, 0.5, 0.75, 1.0)) onProgress(frac)
        return destinationPath
    }
}
