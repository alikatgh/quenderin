package ai.quenderin.core

/**
 * What kind of work a prompt is asking for — the router's classification target.
 * Names are the cross-platform contract (see shared/router-parity-vectors.json).
 */
enum class TaskKind { CODING, REASONING, MULTILINGUAL, GENERAL }

/** The router's pick: which installed model should answer, plus the one-line human reason. */
data class RouteDecision(
    val modelId: String,
    val task: TaskKind,
    val reason: String,
)

/**
 * Picks the best INSTALLED model for a prompt. Twin of iOS `ModelRouter` (Theme of the port:
 * plain substring/code-point scans, NO regex — regex/Unicode-class semantics are exactly where
 * Swift and Kotlin silently diverge). Contract pinned by shared/router-parity-vectors.json +
 * scripts/check_router_parity.py (CI).
 *
 * Routing happens at CONVERSATION boundaries and is surfaced as a SUGGESTION — never a silent
 * mid-conversation swap.
 */
object ModelRouter {

    internal val codingMarkers = listOf(
        "```", "def ", "func ", "fun ", "class ", "import ", "print(", "console.log",
        "function", "compile", "refactor", "debug", "stack trace", "exception",
        "regex", "sql", "python", "javascript", "typescript", "swift", "kotlin",
        "rust", "c++", "segfault", "null pointer", "unit test", "api endpoint", "write code",
    )

    internal val reasoningMarkers = listOf(
        "step by step", "step-by-step", "prove ", "proof", "solve ", "puzzle",
        "logic", "deduce", "how many ", "if x", "therefore", "riddle", "chain of thought",
        "reason through", "think through", "math problem",
    )

    internal val translateMarkers = listOf(
        "translate", "translation", "in spanish", "in french",
        "in german", "in japanese", "in chinese", "into english",
    )

    /** Classify a prompt. Priority when several match: coding > multilingual > reasoning > general. */
    fun classify(prompt: String): TaskKind {
        val lower = prompt.lowercase()
        if (codingMarkers.any { lower.contains(it) }) return TaskKind.CODING
        if (nonLatinLetterShare(prompt) > 0.3 || translateMarkers.any { lower.contains(it) }) {
            return TaskKind.MULTILINGUAL
        }
        if (reasoningMarkers.any { lower.contains(it) }) return TaskKind.REASONING
        return TaskKind.GENERAL
    }

    /**
     * Share of LETTERS outside basic Latin (+ Latin-1/Extended, so accented European text stays
     * "latin"). Iterates CODE POINTS, matching Swift's unicode-scalar walk exactly.
     */
    internal fun nonLatinLetterShare(s: String): Double {
        var letters = 0
        var nonLatin = 0
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            if (Character.isLetter(cp)) {
                letters += 1
                if (cp > 0x24F) nonLatin += 1   // beyond Latin Extended-B
            }
            i += Character.charCount(cp)
        }
        if (letters == 0) return 0.0
        return nonLatin.toDouble() / letters.toDouble()
    }

    internal fun preferredFamilies(task: TaskKind): List<String> = when (task) {
        TaskKind.CODING -> listOf("qwen25-coder", "deepseek-r1", "qwen3", "llama", "mistral", "gemma4", "gemma3", "phi4")
        TaskKind.REASONING -> listOf("deepseek-r1", "qwen3", "llama", "mistral", "gemma4", "gemma3", "phi4", "qwen25-coder")
        TaskKind.MULTILINGUAL -> listOf("qwen3", "gemma4", "gemma3", "llama", "mistral", "deepseek-r1", "phi4", "qwen25-coder")
        TaskKind.GENERAL -> listOf("llama", "mistral", "qwen3", "gemma4", "gemma3", "phi4", "deepseek-r1", "qwen25-coder")
    }

    internal fun taskLabel(task: TaskKind): String = when (task) {
        TaskKind.CODING -> "a coding question"
        TaskKind.REASONING -> "a step-by-step problem"
        TaskKind.MULTILINGUAL -> "a multilingual prompt"
        TaskKind.GENERAL -> "a general question"
    }

    /**
     * The best installed model for this prompt on this device, or null when nothing is installed.
     * Within a family, prefers the LARGEST variant that can load right now.
     */
    fun route(
        prompt: String,
        installed: List<ModelEntry>,
        totalRamGb: Double,
        freeRamGb: Double,
    ): RouteDecision? {
        if (installed.isEmpty()) return null
        val task = classify(prompt)
        val loadable = installed.filter { MemoryFitness.check(it, totalRamGb, freeRamGb).canLoad }
        val pool = loadable.ifEmpty { installed }

        for (family in preferredFamilies(task)) {
            val best = pool.filter { it.id.startsWith(family) }.maxByOrNull { it.paramsBillions }
            if (best != null) {
                return RouteDecision(
                    modelId = best.id,
                    task = task,
                    reason = "${taskLabel(task)} — ${best.label} is the best fit you have installed",
                )
            }
        }
        val best = pool.maxByOrNull { it.paramsBillions }!!
        return RouteDecision(
            modelId = best.id,
            task = task,
            reason = "${taskLabel(task)} — ${best.label} is the largest model you have installed",
        )
    }
}
