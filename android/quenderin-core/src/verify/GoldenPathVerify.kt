package ai.quenderin.core

/**
 * Headless golden-path INTEGRATION check — the Android twin of iOS GoldenPathTests.
 * Proves the M1 -> M2 -> M4 pieces COMPOSE (not just pass in isolation): probe ->
 * recommend -> download(mock) -> load -> chat on ONE shared engine, then the agent loop
 * driving the REAL tool suite through the safety gate. Its own main(), compiled/run
 * separately from CoreVerify so it touches nothing else:
 *
 *   kotlinc (core .kt) src/verify/GoldenPathVerify.kt -include-runtime -d gp.jar
 *   java -cp gp.jar ai.quenderin.core.GoldenPathVerifyKt
 */

private var gpFailures = 0
private fun gp(name: String, cond: Boolean) {
    if (cond) println("  ok   $name") else { println("  FAIL $name"); gpFailures++ }
}

fun main() {
    println("Quenderin golden-path (Android) integration check\n")

    // ONE engine — loaded during onboarding, reused by chat (as MainTabs wires it).
    val engine = MockInferenceEngine(cannedReply = "A taut-line hitch holds well.")
    val onboarding = OnboardingModel(engine, MockModelDownloader())

    // 1) probe -> recommend (jetsam/native-heap selector -> safe 4B on an 8 GB device)
    gp("engine starts unloaded", engine.loadedModelId == null)
    onboarding.start { DeviceProfile(totalRamGB = 8.0, freeRamGB = 6.0) }
    val recommended = (onboarding.phase as? OnboardingPhase.Recommended)?.model
    gp("probe -> recommends qwen3-4b on an 8 GB device", recommended?.id == "qwen3-4b")

    // 2) download(mock) -> load -> ready, into the SAME engine
    onboarding.acceptAndPrepare(recommended ?: ModelRecommender.recommendedModel(8.0))
    gp("onboarding reaches Ready", onboarding.phase is OnboardingPhase.Ready)
    gp("onboarding loaded the recommended model into the shared engine", engine.loadedModelId == "qwen3-4b")

    // 3) chat reuses the onboarding-loaded engine (no reload) and replies
    val chat = ChatModel(engine)
    val reply = chat.send("What knot for a tarp ridgeline?")
    gp("chat replies from the shared, onboarding-loaded engine", reply == "A taut-line hitch holds well.")
    gp("chat transcript is user then assistant", chat.messages.map { it.role } == listOf(Role.USER, Role.ASSISTANT))

    // 4) agent loop with the REAL tool suite + safety gate
    val tools = listOf(CalculatorTool(), UnitConverterTool(), DateCalcTool())
    val run = AgentLoop(
        ScriptedInferenceEngine(listOf(
            """{"tool":"units","input":"20 km to mi"}""",
            """{"answer":"About 12.4 miles."}""",
        )),
        tools,
    ).run("Convert 20 km to miles")
    gp("agent plans -> runs the real tool -> answers", run.haltReason == AgentRun.HaltReason.ANSWERED)
    gp("agent's tool observation carries the real conversion", run.steps.any { it.observation?.contains("12.42") == true })

    val blocked = AgentLoop(
        ScriptedInferenceEngine(listOf("""{"tool":"calculator","input":"delete the files and pay now"}""")),
        tools,
    ).run("do it")
    gp("agent safety-gates a blocked action", blocked.haltReason == AgentRun.HaltReason.BLOCKED)

    println()
    if (gpFailures == 0) println("ALL PASSED") else { println("$gpFailures FAILED"); kotlin.system.exitProcess(1) }
}
