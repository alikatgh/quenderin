package ai.quenderin.core

/** The speed↔quality trade the user picked. */
enum class SpeedPreset { FAST, BALANCED, QUALITY }

/**
 * The model-speed dial: maps Fast / Balanced / Quality to concrete catalog models for a device's
 * RAM. Decode speed is memory-bandwidth-bound — tokens/sec scales ~inversely with model bytes — so
 * the model SIZE is the one speed lever that actually moves the felt experience on a phone (a 1B
 * streams ~6× faster than the 4B). QUALITY is always the device recommendation; FAST/BALANCED step
 * down from it. Bands collapse on small devices (dup entries are fine). Pure + testable; twin of
 * Swift `SpeedPresets`.
 */
object SpeedPresets {
    data class Choice(val fast: ModelEntry, val balanced: ModelEntry, val quality: ModelEntry) {
        fun model(preset: SpeedPreset): ModelEntry = when (preset) {
            SpeedPreset.FAST -> fast
            SpeedPreset.BALANCED -> balanced
            SpeedPreset.QUALITY -> quality
        }

        /** Which preset a model id corresponds to, or null when it's a manual pick outside the dial.
         *  Checked quality-first so on small devices (collapsed bands) the strongest label wins. */
        fun presetFor(modelId: String): SpeedPreset? = when (modelId) {
            quality.id -> SpeedPreset.QUALITY
            balanced.id -> SpeedPreset.BALANCED
            fast.id -> SpeedPreset.FAST
            else -> null
        }
    }

    fun forDevice(totalRamGb: Double): Choice {
        val quality = ModelRecommender.recommendedModel(totalRamGb)
        val fastCand: ModelEntry
        val balancedCand: ModelEntry
        when {
            totalRamGb < 3.0 -> { fastCand = entry("llama32-1b-q2"); balancedCand = entry("llama32-1b") }
            totalRamGb < 10.0 -> { fastCand = entry("llama32-1b"); balancedCand = entry("llama32-3b") }
            else -> { fastCand = entry("llama32-3b"); balancedCand = entry("qwen3-4b") }
        }
        // Clamp so the dial is never upside-down: on the tiniest devices the RECOMMENDED model is
        // already the smallest, so a band's "balanced" could outweigh quality — collapse it instead.
        val balanced = if (balancedCand.ramGB > quality.ramGB) quality else balancedCand
        val fast = if (fastCand.ramGB > balanced.ramGB) balanced else fastCand
        return Choice(fast = fast, balanced = balanced, quality = quality)
    }

    private fun entry(id: String): ModelEntry = ModelCatalog.entry(id) ?: ModelCatalog.smallest
}
