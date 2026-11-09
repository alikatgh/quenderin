package ai.quenderin.core

/**
 * Explicit model selection, adapted from Turnstone 1.9.
 *
 * A named model stays named. Missing, unreadable, incompatible, and
 * memory-blocked selections wait with a reason instead of being replaced.
 * No explicit id still means the first-run recommender may choose.
 * This type does not touch the disk or run a model. Experimental source
 * support is not tested inference and not store availability.
 */
enum class ModelAvailability { PRESENT, MISSING, UNREADABLE, INCOMPATIBLE, BLOCKED }

enum class ModelEvidence { ORDINARY, EXPERIMENTAL_SOURCE }

sealed interface ModelHoldDecision {
    data object Recommend : ModelHoldDecision
    data class Use(val modelId: String, val evidence: ModelEvidence, val notice: String) : ModelHoldDecision
    data class Wait(val modelId: String, val availability: ModelAvailability, val message: String) : ModelHoldDecision
}

object ModelSelectionHold {
    const val EXPERIMENTAL_SOURCE_NOTICE =
        "Experimental engine support. This selection is source integration, not tested inference, and it is not a store release."

    fun message(modelId: String, availability: ModelAvailability): String {
        val why = when (availability) {
            ModelAvailability.MISSING -> "is not on this device"
            ModelAvailability.UNREADABLE -> "cannot be read"
            ModelAvailability.INCOMPATIBLE -> "does not run in this build"
            ModelAvailability.BLOCKED -> "does not fit the current memory gate"
            ModelAvailability.PRESENT -> "is ready"
        }
        return "\"$modelId\" $why. This choice stays selected and was not replaced. Choose another model to continue."
    }

    fun decide(explicitModelId: String?, availability: ModelAvailability, evidence: ModelEvidence): ModelHoldDecision {
        val modelId = explicitModelId?.trim().orEmpty()
        if (modelId.isEmpty()) return ModelHoldDecision.Recommend
        if (availability == ModelAvailability.PRESENT) {
            val notice = if (evidence == ModelEvidence.EXPERIMENTAL_SOURCE) EXPERIMENTAL_SOURCE_NOTICE else ""
            return ModelHoldDecision.Use(modelId, evidence, notice)
        }
        val detail = message(modelId, availability)
        val full = if (evidence == ModelEvidence.EXPERIMENTAL_SOURCE) "$detail $EXPERIMENTAL_SOURCE_NOTICE" else detail
        return ModelHoldDecision.Wait(modelId, availability, full)
    }

    fun evidenceFor(model: ModelEntry?): ModelEvidence =
        if (model != null && (ModelRuntimeSupport.requiresPrism(model) || ModelRuntimeSupport.isMuse(model)))
            ModelEvidence.EXPERIMENTAL_SOURCE else ModelEvidence.ORDINARY
}
