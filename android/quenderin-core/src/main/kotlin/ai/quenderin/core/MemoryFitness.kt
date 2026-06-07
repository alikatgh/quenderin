package ai.quenderin.core

enum class MemorySeverity { SAFE, WARNING, CRITICAL, BLOCKED }

data class MemoryCheckResult(
    val canLoad: Boolean,
    val severity: MemorySeverity,
    val requiredGB: Double,
    val availableGB: Double,
    val message: String,
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
    ): MemoryCheckResult {
        val overhead = if (model.paramsBillions <= 3.0) OVERHEAD_BASE else OVERHEAD_LARGE
        val required = model.ramGB * overhead
        val usageAfterLoad = (totalGB - freeGB + required) / totalGB
        return when {
            usageAfterLoad > budgetHard -> MemoryCheckResult(
                false, MemorySeverity.BLOCKED, required, freeGB,
                "Loading ${model.label} needs ~${fmt(required)}GB but only ${fmt(freeGB)}GB is free.",
            )
            usageAfterLoad > budgetWarning -> MemoryCheckResult(
                true, MemorySeverity.WARNING, required, freeGB,
                "${model.label} will leave the system tight.",
            )
            else -> MemoryCheckResult(
                true, MemorySeverity.SAFE, required, freeGB,
                "${model.label} fits comfortably.",
            )
        }
    }

    private fun fmt(v: Double): String = "%.1f".format(v)
}
