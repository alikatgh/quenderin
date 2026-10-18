package ai.quenderin.core

enum class MemorySeverity { SAFE, WARNING, CRITICAL, BLOCKED }

data class MemoryCheckResult(
    val canLoad: Boolean,
    val severity: MemorySeverity,
    val requiredGB: Double,
    val availableGB: Double,
    val message: String,
    /** Headroom left once the model is loaded (free − required); negative when it doesn't fit.
     *  Twin of Swift `remainingAfterLoadGB` — the WARNING message surfaces this figure. */
    val remainingAfterLoadGB: Double = availableGB - requiredGB,
)

/** "Can this device load this model?" — same 0.85/0.65 budgets as Swift/desktop. */
object MemoryFitness {
    const val DEFAULT_BUDGET_HARD = 0.85
    const val DEFAULT_BUDGET_WARNING = 0.65
    const val OVERHEAD_BASE = 1.15
    const val OVERHEAD_LARGE = 1.30

    fun check(
        model: ModelEntry,
        totalGB: Double,
        freeGB: Double,
        budgetHard: Double = DEFAULT_BUDGET_HARD,
        budgetWarning: Double = DEFAULT_BUDGET_WARNING,
        prismRuntimeAvailable: Boolean = ModelRuntimeSupport.supportsBonsai,
        museRuntimeAvailable: Boolean = ModelRuntimeSupport.supportsMuse,
        weeklyTextRuntimeAvailable: Boolean = ModelRuntimeSupport.supportsWeeklyText,
        beamRuntimeAvailable: Boolean = ModelRuntimeSupport.supportsBeam,
    ): MemoryCheckResult {
        val overhead = if (model.paramsBillions <= 3.0 && !ModelRuntimeSupport.requiresMemoryGate(model)) OVERHEAD_BASE else OVERHEAD_LARGE
        val required = ModelRuntimeSupport.memoryFootprintGb(model) * overhead
        val usageAfterLoad = (totalGB - freeGB + required) / totalGB
        return when {
            ModelRuntimeSupport.unsupportedWorkflowReason(model) != null -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB, ModelRuntimeSupport.unsupportedWorkflowReason(model)!!,
            )
            ModelRuntimeSupport.isBeam(model) && (!beamRuntimeAvailable || !ModelRuntimeSupport.isVerifiedBeamManifest(model)) -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB, ModelRuntimeSupport.BEAM_UNAVAILABLE_MESSAGE,
            )
            ModelRuntimeSupport.requiresWeeklyTextRuntime(model) && !weeklyTextRuntimeAvailable -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB, ModelRuntimeSupport.WEEKLY_TEXT_UNAVAILABLE_MESSAGE,
            )
            ModelRuntimeSupport.isMuse(model) && !museRuntimeAvailable -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB, ModelRuntimeSupport.MUSE_UNAVAILABLE_MESSAGE,
            )
            ModelRuntimeSupport.requiresPrism(model) && !prismRuntimeAvailable -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB, ModelRuntimeSupport.UNAVAILABLE_MESSAGE,
            )
            usageAfterLoad > budgetHard -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB,
                "Loading ${model.label} needs ~${fmt(required)}GB of memory — more than this device can safely spare (${fmt(freeGB)}GB free of ${fmt(totalGB)}GB). Close other apps or choose a smaller model.",
            )
            usageAfterLoad > budgetWarning -> MemoryCheckResult(
                true, MemorySeverity.WARNING, required, freeGB,
                // Twin-drift fix: surface the concrete remaining-GB figure like iOS, not the numberless
                // "will leave the system tight" — same WARNING condition, actionable-message parity.
                "${model.label} will leave only ${fmt(freeGB - required)}GB free. System may be slow.",
            )
            else -> MemoryCheckResult(
                true, MemorySeverity.SAFE, required, freeGB,
                "${model.label} fits comfortably.",
            )
        }
    }

    private fun fmt(v: Double): String = "%.1f".format(v)
}
