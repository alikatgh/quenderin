package ai.quenderin.core

/**
 * On-device pace for local chat and tools.
 *
 * A missing tool decision runs nothing. Calculator, units, and dates start on
 * and can be turned off. Reply text is checked here, not by a second model and
 * not by a network call. Photos and speech stay unloaded until those screens open.
 * DeepSeek and the remote computer path are separate and are not handled here.
 */
object LocalPace {
    val builtinIds = listOf("calculator", "units", "date")
    const val HELD = "Nothing ran."
    const val WITHHELD = "Refused: the result mentions a blocked action. Nothing was shown."
    const val PRACTICE_LINE =
        "Calculator, units, and dates answer practice questions on this device. This does not test the model."
    const val STAYS_HERE = "Local chats, checks, and tools stay on this device. No account."
    const val ROLE_CHECK = "On this device, before you see the reply"
    const val ROLE_PERCEPTION = "Separate, and not loaded with chat"
    const val HELD_REPLY =
        "Held on this device. This reply mentions a sensitive action, so it is not shown. Nothing was sent."

    private val off = HashSet<String>()

    fun isOn(name: String): Boolean = name !in off

    fun setOn(name: String, on: Boolean) {
        if (on) off.remove(name) else off.add(name)
    }

    /** A blank name, or a builtin tool the person turned off, does not run. */
    fun admits(name: String): Boolean {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return false
        if (trimmed in builtinIds && !isOn(trimmed)) return false
        return true
    }

    /** Replace a blocked tool result before it is shown or fed back. */
    fun present(text: String): String = if (SafetyBlocklist.isBlocked(text)) WITHHELD else text

    fun practiceOk(): Boolean =
        CalculatorTool().run("2+2") == "4" &&
            UnitConverterTool().run("1 km to m") == "1 km = 1000 m" &&
            DateCalcTool().run("2026-06-08 plus 90 days") == "2026-09-06"

    fun offered(tools: List<AgentTool>): List<AgentTool> = tools.filter { admits(it.name) }

    /** Status under the model name. Empty until the person has typed, so first open stays one line. */
    fun statusLine(firstUserText: String?, badge: String): String {
        val trimmed = firstUserText?.trim().orEmpty()
        if (trimmed.isEmpty()) return badge
        return ConversationLibrary.titleFromFirstUserMessage(trimmed) + " · " + badge
    }
}

fun verifyLocalPace() {
    require(LocalPace.admits("calculator"))
    require(!LocalPace.admits("  "))
    require(LocalPace.present("2 + 2 = 4") == "2 + 2 = 4")
    require(LocalPace.present("delete everything then pay") == LocalPace.WITHHELD)
    LocalPace.setOn("calculator", false)
    require(!LocalPace.admits("calculator"))
    require(LocalPace.admits("units"))
    LocalPace.setOn("calculator", true)
    require(LocalPace.practiceOk())
    require(!LocalPace.STAYS_HERE.contains("http"))
    require(LocalPace.PRACTICE_LINE.contains("does not test the model"))
}
