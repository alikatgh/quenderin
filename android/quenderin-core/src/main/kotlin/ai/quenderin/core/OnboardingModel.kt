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
    // Persistence of the last successfully-loaded model id across launches (SharedPreferences in
    // the app layer; injectable for tests). Without it, every cold launch replayed first-run
    // onboarding even though the model was sitting on disk — the app forgot your model. The core
    // is file-system-free, so "is the remembered model's file still on disk?" is a seam too.
    // Twin of the Swift UserDefaults seam (same key, see ACTIVE_MODEL_PREFS_KEY).
    private val recallActiveModelID: () -> String? = { null },
    private val rememberActiveModelID: (String?) -> Unit = {},
    private val activeModelFileExists: (ModelEntry) -> Boolean = { false },
) {
    companion object {
        /** Preferences key for the remembered model id — same string as Swift's
         *  `activeModelDefaultsKey` so the two platforms document each other. */
        const val ACTIVE_MODEL_PREFS_KEY = "quenderin.activeModelID"
    }

    var phase: OnboardingPhase = OnboardingPhase.Idle
        private set(value) {
            field = value
            if (value is OnboardingPhase.Recommended) lastRecommended = value
            onChange(value)
        }

    /** The most recent recommendation — where a CANCELLED download returns (a change of mind is
     *  not a failure). Kept by the phase setter so both start() paths feed it. */
    private var lastRecommended: OnboardingPhase.Recommended? = null

    /**
     * The full selector result (rationale + heat/battery + alternatives) when the pick
     * came from [AndroidModelSelector]. Null on the simple RAM-band path.
     */
    var selection: ModelSelection? = null
        private set

    /**
     * World-class path: a full device profile → [AndroidModelSelector] (native-heap
     * budget + chip + disk + heat/battery aware). The app builds the profile from the
     * framework (`Build.SOC_MODEL`, `ActivityManager.MemoryInfo`, `StatFs`). Twin of the
     * iOS onboarding's selector path.
     */
    fun start(profile: AndroidDeviceProfile) {
        phase = OnboardingPhase.Probing
        val sel = AndroidModelSelector.select(profile)
        selection = sel
        if (sel.confidence == SelectionConfidence.UNSUPPORTED) {
            // Even the smallest model can't run here — fail honestly, don't push a doomed download.
            phase = OnboardingPhase.Failed(sel.rationale)
            return
        }
        val severity = when (sel.confidence) {
            SelectionConfidence.COMFORTABLE -> MemorySeverity.SAFE
            SelectionConfidence.TIGHT -> MemorySeverity.WARNING
            SelectionConfidence.FORCED -> MemorySeverity.CRITICAL
            SelectionConfidence.UNSUPPORTED -> MemorySeverity.CRITICAL   // handled above; here for exhaustiveness
        }
        phase = OnboardingPhase.Recommended(
            sel.model,
            MemoryCheckResult(
                canLoad = true,
                severity = severity,
                requiredGB = sel.estimatedRuntimeGb,
                availableGB = sel.usableMemoryGb,
                message = sel.rationale,
            ),
        )
    }

    /**
     * Probe + recommend. [probe] is injected (not read from the OS here) so tests are
     * deterministic. Lands on [OnboardingPhase.Recommended], or [OnboardingPhase.Failed]
     * if even the recommended model can't fit.
     */
    fun start(probe: () -> DeviceProfile) {
        phase = OnboardingPhase.Probing
        val device = probe()
        // Fitness-aware, not just the RAM band: the band can pick a model the memory gate then
        // blocks (a 12–16 GB device band-picks the 14B → over the 85% budget), which used to land
        // first-run straight on Failed. Offer the largest model that actually loads instead.
        val model = ModelRecommender.bestInstallableModel(device.totalRamGB, device.freeRamGB)
        val fitness = MemoryFitness.check(model, device.totalRamGB, device.freeRamGB)
        phase = if (fitness.canLoad) {
            OnboardingPhase.Recommended(model, fitness)
        } else {
            OnboardingPhase.Failed(fitness.message)
        }
    }

    /**
     * Relaunch fast-path: a model that loaded successfully before, and whose file is still on
     * disk, goes straight back to [OnboardingPhase.Ready] — no first-run onboarding replay. Only
     * from the pristine [OnboardingPhase.Idle] (an explicit retry must show the choice), and
     * [acceptAndPrepare] re-runs the download integrity gate before trusting the file, so a
     * corrupted leftover still falls back to normal first-run onboarding. Blocking; call off-main
     * at launch. Twin of the fast-path at the top of Swift `start()`.
     */
    fun restoreAtLaunch(): Boolean {
        if (phase !is OnboardingPhase.Idle) return false
        val remembered = recallActiveModelID()?.let { ModelCatalog.entry(it) } ?: return false
        if (!activeModelFileExists(remembered)) return false
        acceptAndPrepare(remembered)
        if (phase is OnboardingPhase.Ready) return true
        // Restore didn't make it (corrupt file while offline, engine failure…) — back to the
        // pristine screen for the normal first-run flow, exactly as the Swift fast-path falls
        // through to a fresh recommendation.
        phase = OnboardingPhase.Idle
        return false
    }

    /** Proceed from Recommended → download → load → ready for [model]. Blocking; call off-main. */
    fun acceptAndPrepare(model: ModelEntry) {
        // The model we'll fall back to if this one fails to load (a model SWITCH from Settings) — so a
        // bad pick can't strand the user with no model (H1). null on first-run onboarding.
        val previousId = engine.loadedModelId

        val path = try {
            phase = OnboardingPhase.Downloading(model, 0.0)
            downloader.download(model) { frac -> phase = OnboardingPhase.Downloading(model, frac) }
        } catch (c: DownloadCancelledException) {
            // User cancel → back to the recommendation screen, not a Failed dead end. The engine
            // kept the .part, so a retry resumes. (Twin of the Apple install() cancel path.)
            phase = lastRecommended ?: OnboardingPhase.Failed("Download cancelled.")
            return
        } catch (t: Throwable) {
            phase = OnboardingPhase.Failed("Download failed: ${t.message}")
            return
        }
        try {
            // Interrupt any in-flight generation so the switch's load() isn't blocked behind it (M3).
            engine.requestCancel()
            phase = OnboardingPhase.Loading(model)
            engine.load(model, path)
        } catch (t: Throwable) {
            // load() already freed the previously-loaded model before failing (free-before-reassign),
            // so on a failed SWITCH restore the prior model rather than leaving the engine empty (H1).
            val previous = previousId
                ?.takeIf { it != model.id }
                ?.let { id -> ModelCatalog.models.firstOrNull { it.id == id } }
            if (previous != null && restore(previous)) {
                phase = OnboardingPhase.Ready(previous)
                rememberActiveModelID(previous.id)
            } else {
                phase = OnboardingPhase.Failed("Couldn't load ${model.label}: ${t.message}")
            }
            return
        }
        phase = OnboardingPhase.Ready(model)
        rememberActiveModelID(model.id)   // next cold launch restores this model directly
    }

    /** Best-effort reload of a previously-working model after a failed switch. Its file is still on
     *  disk (download() returns the existing path without re-fetching). Returns true on success. */
    private fun restore(model: ModelEntry): Boolean = try {
        engine.load(model, downloader.download(model) {})
        true
    } catch (t: Throwable) {
        false
    }
}
