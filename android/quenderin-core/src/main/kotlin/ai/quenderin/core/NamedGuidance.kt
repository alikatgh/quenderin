package ai.quenderin.core

/**
 * Named guidance, adapted from Turnstone 1.9 skills.
 *
 * At most one note is active, and only because the user named it. A note has
 * text. It does not choose a model, temperature, or tool grant. The shell
 * fills `{{model}}` from the selected model's label. Other `{{...}}` stay
 * as written.
 */
sealed interface GuidanceResult {
    data object Ok : GuidanceResult
    data class Rejected(val message: String) : GuidanceResult
}

object NamedGuidance {
    const val NAME_MESSAGE = "Guidance names are 1-48 letters, digits, spaces, or hyphens."
    const val TEXT_MESSAGE = "Guidance text must be 1-1500 characters."
    const val CAPACITY_MESSAGE = "The guidance notebook already holds 24 notes. Remove one before saving another."

    fun unknownMessage(name: String) = "No guidance named \"$name\". Choose a saved note by its exact name."

    fun fillModelPlaceholder(text: String, modelLabel: String): String {
        val label = modelLabel.trim().take(80)
        return text.replace("{{model}}", label)
    }

    fun body(name: String, text: String, modelLabel: String): String =
        "Guidance note \"$name\" (instructions only; it does not change the model or which tools can run):\n${fillModelPlaceholder(text, modelLabel)}"

    fun append(base: String, rendered: String?): String {
        if (rendered.isNullOrEmpty()) return base
        if (base.isEmpty()) return rendered
        return "$base\n\n$rendered"
    }
}

class GuidanceNotebook {
    private val notes = LinkedHashMap<String, String>()
    var active: String? = null
        private set

    fun noteCount(): Int = notes.size

    fun save(name: String, text: String): GuidanceResult {
        val cleanedName = normalizeName(name) ?: return GuidanceResult.Rejected(NamedGuidance.NAME_MESSAGE)
        val cleanedText = normalizeText(text) ?: return GuidanceResult.Rejected(NamedGuidance.TEXT_MESSAGE)
        if (!notes.containsKey(cleanedName) && notes.size >= MAX_NOTES) {
            return GuidanceResult.Rejected(NamedGuidance.CAPACITY_MESSAGE)
        }
        notes[cleanedName] = cleanedText
        return GuidanceResult.Ok
    }

    /** Activate a saved note by its exact name. Does not create a note and does not search. */
    fun select(name: String): GuidanceResult {
        val cleanedName = normalizeName(name)
        if (cleanedName == null || !notes.containsKey(cleanedName)) {
            return GuidanceResult.Rejected(NamedGuidance.unknownMessage(cleanedName ?: name.trim()))
        }
        active = cleanedName
        return GuidanceResult.Ok
    }

    fun clear() { active = null }

    fun render(modelLabel: String): String? {
        val name = active ?: return null
        val text = notes[name] ?: return null
        return NamedGuidance.body(name, text, modelLabel)
    }

    companion object {
        const val MAX_NOTES = 24

        private fun normalizeName(name: String): String? {
            val trimmed = name.trim()
            if (trimmed.length !in 1..48) return null
            trimmed.forEachIndexed { index, char ->
                val letter = char in 'A'..'Z' || char in 'a'..'z'
                val digit = char in '0'..'9'
                val space = char == ' '
                val hyphen = char == '-'
                if (index == 0) {
                    if (!(letter || digit)) return null
                } else if (!(letter || digit || space || hyphen)) {
                    return null
                }
            }
            return trimmed
        }

        private fun normalizeText(text: String): String? {
            val trimmed = text.trim()
            if (trimmed.length !in 1..1500) return null
            if (trimmed.any { it.code < 32 && it != '\n' }) return null
            return trimmed
        }
    }
}
