package ai.quenderin.core

/** Device facts the recommender needs. On Android these come from `ActivityManager.MemoryInfo`. */
data class DeviceProfile(val totalRamGB: Double, val freeRamGB: Double)

/** First-run lifecycle. A sealed type so the Compose layer can `when`-exhaust it. */
sealed interface OnboardingPhase {
    object Idle : OnboardingPhase
    object Probing : OnboardingPhase
    data class Recommended(val model: ModelEntry, val fitness: MemoryCheckResult) : OnboardingPhase
    data class Downloading(val model: ModelEntry, val fraction: Double) : OnboardingPhase
    data class Loading(val model: ModelEntry) : OnboardingPhase
    data class Ready(val model: ModelEntry) : OnboardingPhase
    data class Failed(val reason: String) : OnboardingPhase
}

/**
 * Drives M1 onboarding: probe hardware → recommend a model → check it fits → download
 * → load into the engine → ready. Pure Kotlin and dependency-free (it pushes state to
 * an [onChange] listener rather than a StateFlow) so it unit-tests on the JVM; the
 * Compose layer maps [onChange] into `mutableStateOf` and runs the blocking steps off
 * the main thread. Twin of Swift `OnboardingModel` (probe → recommend → download →
 * load → ready).
 */
class OnboardingModel(
    private val engine: InferenceEngine,
    private val downloader: ModelDownloader,
    var onChange: (OnboardingPhase) -> Unit = {},
) {
    var phase: OnboardingPhase = OnboardingPhase.Idle
        private set(value) {
            field = value
            onChange(value)
        }

    /**
     * Probe + recommend. [probe] is injected (not read from the OS here) so tests are
     * deterministic. Lands on [OnboardingPhase.Recommended], or [OnboardingPhase.Failed]
     * if even the recommended model can't fit.
     */
    fun start(probe: () -> DeviceProfile) {
        phase = OnboardingPhase.Probing
        val device = probe()
        val model = ModelRecommender.recommendedModel(device.totalRamGB)
        val fitness = MemoryFitness.check(model, device.totalRamGB, device.freeRamGB)
        phase = if (fitness.canLoad) {
            OnboardingPhase.Recommended(model, fitness)
        } else {
            OnboardingPhase.Failed(fitness.message)
        }
    }

    /** Proceed from Recommended → download → load → ready for [model]. Blocking; call off-main. */
    fun acceptAndPrepare(model: ModelEntry) {
        val path = try {
            phase = OnboardingPhase.Downloading(model, 0.0)
            downloader.download(model) { frac -> phase = OnboardingPhase.Downloading(model, frac) }
        } catch (t: Throwable) {
            phase = OnboardingPhase.Failed("Download failed: ${t.message}")
            return
        }
        try {
            phase = OnboardingPhase.Loading(model)
            engine.load(model, path)
        } catch (t: Throwable) {
            phase = OnboardingPhase.Failed("Load failed: ${t.message}")
            return
        }
        phase = OnboardingPhase.Ready(model)
    }
}
