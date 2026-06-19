package ai.quenderin.core

/** How sure we are about a pick — drives the UI's "great fit / tight / limited" copy. */
enum class SelectionConfidence { COMFORTABLE, TIGHT, FORCED }

/** A model considered during selection, with why it was (or wasn't) chosen. */
data class ModelOption(
    val model: ModelEntry,
    val viable: Boolean,
    val estimatedTokensPerSecond: Double,
    val estimatedRuntimeGb: Double,
    val note: String,
)

/** The result of picking a model for an Android device. */
data class ModelSelection(
    val model: ModelEntry,
    val estimatedTokensPerSecond: Double,
    val estimatedRuntimeGb: Double,
    val appMemoryBudgetGb: Double,
    val usableMemoryGb: Double,
    val memoryHeadroomGb: Double,
    val thermalBattery: ThermalBatteryEstimate,
    val confidence: SelectionConfidence,
    val rationale: String,
    val device: AndroidDeviceProfile,
    val alternatives: List<ModelOption>,
)

/**
 * World-class on-device model picking for Android — the twin of iOS `IPhoneModelSelector`,
 * with Android's memory reality. It gates every candidate on THREE realities and explains
 * the result:
 *  1. **Native-heap budget** — what a JNI/llama.cpp allocation can use before the
 *     low-memory-killer, NOT the tiny Dalvik per-app cap, and NOT raw total RAM.
 *  2. **Chip throughput** — fast enough to feel alive on this SoC?
 *  3. **Disk** — does the GGUF fit, with margin?
 * It defaults to the largest GENERAL-PURPOSE model that's *comfortable* (snappy + real
 * headroom) and surfaces bigger/tight and specialized models as transparent alternatives.
 * Because Android flagships reach 12–16 GB, this unlocks 7B-class defaults that no 8 GB
 * iPhone can hold. Pure logic on an injected profile, so every pick is unit-tested.
 */
object AndroidModelSelector {

    const val MEMORY_HEADROOM = 0.85
    const val MIN_TOKENS_PER_SECOND = 7.0
    const val COMFORT_TOKENS_PER_SECOND = 8.0
    const val COMFORT_HEADROOM_FRACTION = 0.25
    const val REFERENCE_CONTEXT_TOKENS = 4096
    const val DISK_MARGIN_GB = 0.5

    /** General-purpose models, best → smallest. Same intent order as iOS/desktop. */
    val defaultPreferenceIds = listOf(
        "qwen3-14b", "llama3-8b", "mistral-7b", "qwen3-4b",
        "gemma3-4b", "phi4-mini", "llama32-3b", "llama32-1b", "llama32-1b-q2",
    )

    /** Task-specific models — offered, never auto-picked. */
    val specializedNotes = mapOf(
        "qwen25-coder-7b" to "better for coding & tool use",
        "deepseek-r1-7b" to "better for step-by-step reasoning",
    )

    // --- Estimators (pure, identical to the iOS model) ---

    fun weightsGb(model: ModelEntry): Double {
        val bits = Quantization.info(model.quantization)?.bitsPerWeight ?: 4.5
        return model.paramsBillions * bits / 8.0
    }

    fun estimatedRuntimeGb(model: ModelEntry, contextTokens: Int = REFERENCE_CONTEXT_TOKENS): Double {
        val w = weightsGb(model)
        val activations = w * 0.10
        val kvCache = contextTokens / 4096.0 * (0.10 + 0.03 * model.paramsBillions)
        return w + activations + kvCache + 0.25
    }

    /** Stock-llama.cpp decode tok/s; reference rate scaled by the SoC's relative score. */
    fun estimatedTokensPerSecond(model: ModelEntry, soc: AndroidSoc): Double =
        75.0 / (model.paramsBillions + 1.7) * soc.inferenceScore

    fun estimatedDownloadGb(model: ModelEntry): Double = weightsGb(model)

    // --- Selection ---

    fun select(device: AndroidDeviceProfile, catalog: List<ModelEntry> = ModelCatalog.models): ModelSelection {
        val usableGb = device.appMemoryBudgetGb * MEMORY_HEADROOM

        fun evaluate(model: ModelEntry): ModelOption {
            val runtime = estimatedRuntimeGb(model)
            val tokS = estimatedTokensPerSecond(model, device.soc)
            val download = estimatedDownloadGb(model)
            val fitsMemory = runtime <= usableGb
            val fastEnough = tokS >= MIN_TOKENS_PER_SECOND
            val fitsDisk = device.freeDiskGb >= download + DISK_MARGIN_GB
            val viable = fitsMemory && fastEnough && fitsDisk
            val note = when {
                !fitsMemory -> "needs ~%.1f GB, over your ~%.1f GB usable budget".format(runtime, usableGb)
                !fastEnough -> "~%.0f tok/s on the %s — too slow".format(tokS, device.soc.displayName)
                !fitsDisk -> "needs ~%.1f GB free disk".format(download + DISK_MARGIN_GB)
                else -> "~%.0f tok/s, uses ~%.1f GB".format(tokS, runtime)
            }
            return ModelOption(model, viable, tokS, runtime, note)
        }

        fun isComfortable(o: ModelOption): Boolean =
            o.viable &&
                (usableGb - o.estimatedRuntimeGb) >= o.estimatedRuntimeGb * COMFORT_HEADROOM_FRACTION &&
                o.estimatedTokensPerSecond >= COMFORT_TOKENS_PER_SECOND

        val options = defaultPreferenceIds.mapNotNull { id -> catalog.firstOrNull { it.id == id } }.map(::evaluate)

        // Prefer the largest COMFORTABLE model; else the largest merely-viable (tight) one.
        val pickIndex = options.indexOfFirst(::isComfortable).takeIf { it >= 0 }
            ?: options.indexOfFirst { it.viable }.takeIf { it >= 0 }

        val specialized = specializedNotes.keys.sorted().mapNotNull { id ->
            val model = catalog.firstOrNull { it.id == id } ?: return@mapNotNull null
            val o = evaluate(model)
            if (!o.viable) null else o.copy(note = "${specializedNotes[id]} · ${o.note}")
        }

        if (pickIndex == null) {
            val sm = ModelCatalog.smallest
            val runtime = estimatedRuntimeGb(sm)
            val tokS = estimatedTokensPerSecond(sm, device.soc)
            return ModelSelection(
                model = sm,
                estimatedTokensPerSecond = tokS,
                estimatedRuntimeGb = runtime,
                appMemoryBudgetGb = device.appMemoryBudgetGb,
                usableMemoryGb = usableGb,
                memoryHeadroomGb = maxOf(0.0, usableGb - runtime),  // clamp: negative headroom is meaningless (forced path)
                thermalBattery = ThermalBattery.estimate(sm, device.soc, device.batteryMAh, tokS),
                confidence = SelectionConfidence.FORCED,
                rationale = "${device.deviceName} is very memory-constrained (~%.1f GB usable). ".format(usableGb) +
                    "Using the smallest model, ${sm.label}, so it stays responsive.",
                device = device,
                alternatives = options,
            )
        }

        val pick = options[pickIndex]
        val biggerGated = options.take(pickIndex)
        val headroom = usableGb - pick.estimatedRuntimeGb
        val comfortable = isComfortable(pick)
        val speedWord = when {
            pick.estimatedTokensPerSecond >= 15 -> "comfortably"
            pick.estimatedTokensPerSecond >= 9 -> "smoothly"
            else -> "usably"
        }
        val rationale = "%s for your %s: ~%.0f tok/s on the %s (%s), using ~%.1f GB of your ~%.1f GB native-memory budget (%.1f GB headroom).".format(
            pick.model.label, device.deviceName, pick.estimatedTokensPerSecond,
            device.soc.displayName, speedWord, pick.estimatedRuntimeGb, device.appMemoryBudgetGb, headroom,
        )

        return ModelSelection(
            model = pick.model,
            estimatedTokensPerSecond = pick.estimatedTokensPerSecond,
            estimatedRuntimeGb = pick.estimatedRuntimeGb,
            appMemoryBudgetGb = device.appMemoryBudgetGb,
            usableMemoryGb = usableGb,
            memoryHeadroomGb = headroom,
            thermalBattery = ThermalBattery.estimate(pick.model, device.soc, device.batteryMAh, pick.estimatedTokensPerSecond),
            confidence = if (comfortable) SelectionConfidence.COMFORTABLE else SelectionConfidence.TIGHT,
            rationale = rationale,
            device = device,
            alternatives = biggerGated + specialized,
        )
    }
}
