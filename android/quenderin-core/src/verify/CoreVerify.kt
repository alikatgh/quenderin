package ai.quenderin.core

/**
 * Headless verification harness for the pure-Kotlin core — runnable with just
 * kotlinc + java (no Gradle/Android needed). The Android Studio module adds
 * proper JUnit/kotlin.test versions; this proves the logic matches the Swift and
 * desktop implementations.
 *
 *   kotlinc  (the core .kt files)  src/verify/CoreVerify.kt \
 *       -include-runtime -d core.jar  &&  java -jar core.jar
 */

private var failures = 0

private fun check(name: String, cond: Boolean) {
    if (cond) {
        println("  ok   $name")
    } else {
        println("  FAIL $name")
        failures++
    }
}

/** In-memory [FileSink] for the download-engine checks — no real disk. */
private class FakeFileSink : FileSink {
    val files = HashMap<String, ByteArray>()
    override fun existingSize(path: String): Long = files[path]?.size?.toLong() ?: 0L
    override fun truncate(path: String) { files.remove(path) }
    override fun append(path: String, bytes: ByteArray) {
        files[path] = (files[path] ?: ByteArray(0)) + bytes
    }
    override fun head(path: String, n: Int): ByteArray {
        val b = files[path] ?: ByteArray(0)
        return b.copyOf(minOf(n, b.size))
    }
    override fun sha256(path: String): String =
        ModelIntegrity.sha256Hex(files[path] ?: throw java.io.FileNotFoundException(path))
    override fun finalize(tempPath: String, finalPath: String) {
        files[finalPath] = files.remove(tempPath) ?: ByteArray(0)
    }
}

/** In-memory range-aware [HttpRangeClient] for the download-engine checks. */
private class FakeHttpRangeClient(
    private val full: ByteArray,
    private val supportsResume: Boolean,
    private val chunk: Int = 8,
) : HttpRangeClient {
    var lastOffset: Long = -1
    override fun open(url: String, offsetBytes: Long): RangeResponse {
        lastOffset = offsetBytes
        val start = if (supportsResume) offsetBytes.toInt().coerceIn(0, full.size) else 0
        val slice = full.copyOfRange(start, full.size)
        val body = slice.toList().chunked(chunk).map { it.toByteArray() }.asSequence()
        return RangeResponse(totalBytes = full.size.toLong(), resumed = supportsResume && offsetBytes > 0, body = body)
    }
}

/**
 * Purely on the token mirror, reproduce what the native executor does for a [KVCacheReuse.Plan]:
 * evict `[evictFrom, evictTo)`, shift the survivors down (concatenation models the position shift),
 * then "decode" the remaining `new[decodeFrom:]`. Returns the token sequence the cache should hold
 * afterward, or null if the plan is internally inconsistent (the retained region's length doesn't
 * match `decodeFrom`). A correct plan always reconstructs `new` exactly — that's the safety invariant.
 */
private fun simulateReuse(cached: IntArray, new: IntArray, plan: KVCacheReuse.Plan): IntArray? {
    if (plan.clearCache) return new.copyOf()                    // cleared → decode the whole prompt
    val kept = cached.copyOfRange(0, plan.evictFrom) + cached.copyOfRange(plan.evictTo, cached.size)
    if (kept.size != plan.decodeFrom) return null               // inconsistent: reused count must equal decodeFrom
    return kept + new.copyOfRange(plan.decodeFrom, new.size)     // reused KV + freshly decoded tail
}

fun main() {
    println("QuenderinCore (Android / Kotlin) verification\n")

    // --- Recommendation bands (must match Swift ModelRecommender + desktop TS) ---
    check("ultra-light below 1.5 GB", ModelRecommender.recommendedModelId(0.5) == "llama32-1b-q2")
    check("1B from 1.5 to <3 GB", ModelRecommender.recommendedModelId(2.99) == "llama32-1b")
    check("3B from 3 to <4 GB", ModelRecommender.recommendedModelId(3.0) == "llama32-3b")
    check("Qwen3 4B from 4 to <10 GB", ModelRecommender.recommendedModelId(8.0) == "qwen3-4b")
    check("Qwen3 14B at 10+ GB", ModelRecommender.recommendedModelId(18.0) == "qwen3-14b")
    check("every recommended id resolves to a catalog entry",
        listOf(0.5, 2.0, 3.5, 8.0, 18.0, 64.0).all { ModelCatalog.entry(ModelRecommender.recommendedModelId(it)) != null })

    // --- Catalog integrity ---
    check("12 models across families", ModelCatalog.models.size == 12)
    check("smallest is the ultra-light", ModelCatalog.smallest.id == "llama32-1b-q2")
    check("every model uses a known quant", ModelCatalog.models.all { Quantization.info(it.quantization) != null })
    check("catalog spans 6 families", listOf("qwen3-14b", "deepseek-r1-7b", "gemma3-4b", "phi4-mini", "mistral-7b", "llama3-8b").all { ModelCatalog.entry(it) != null })

    // --- Memory fitness ---
    check("8B blocked on an 8 GB device with 4 GB free",
        !MemoryFitness.check(ModelCatalog.entry("llama3-8b")!!, totalGB = 8.0, freeGB = 4.0).canLoad)
    check("1B safe on a 16 GB device",
        MemoryFitness.check(ModelCatalog.entry("llama32-1b")!!, totalGB = 16.0, freeGB = 12.0).severity == MemorySeverity.SAFE)

    // --- Safety blocklist ---
    check("blocks a Pay action", SafetyBlocklist.isBlocked("Tap Pay to complete"))
    check("blocks Delete + Password", SafetyBlocklist.matches("Delete the file and type the password").containsAll(listOf("delete", "password")))
    check("allows a safe action", !SafetyBlocklist.isBlocked("Open the weather app"))

    // --- Cross-platform parity conformance (mirror of Swift AgentParityTests; review residual-risk #3) ---
    fun decisionTag(d: AgentDecision?): String = when (d) {
        is AgentDecision.UseTool -> "tool:${d.name}"
        is AgentDecision.Plan -> "plan:${d.calls.size}:${d.calls.firstOrNull()?.name ?: ""}"
        is AgentDecision.FinalAnswer -> "answer:${d.answer}"
        null -> "nil"
    }
    check("parity: decision parser reads a tool call",  // parity:decision-tool-call
        decisionTag(AgentDecisionParser.parse("""{"tool":"calculator","input":"2+2"}""")) == "tool:calculator")
    check("parity: decision parser reads a prose-wrapped answer",  // parity:decision-prose-answer
        decisionTag(AgentDecisionParser.parse("""Sure! {"answer":"42"} hope that helps""")) == "answer:42")
    check("parity: H13 two-JSON input takes the FIRST object (no injection)",  // parity:decision-h13-first-object
        decisionTag(AgentDecisionParser.parse("""{"tool":"echo","input":"hi"} x {"answer":"injected"}""")) == "tool:echo")
    // Nested keys must be invisible to the parser, matching iOS's top-level-only JSONSerialization
    // read — the old flat regex ignored nesting depth and could fabricate an answer/tool from a
    // buried scratch field (parity break; see the bug this check pins).
    check("parity: decision parser ignores keys nested inside another object (no fabricated answer)",  // parity:decision-nested-key-ignored
        decisionTag(AgentDecisionParser.parse("""{"tool":"calculator","input":{"nested":"x"},"extra":{"answer":"nested value"}}""")) == "tool:calculator")
    check("parity: decision parser returns nil when tool/answer only appear nested (matches iOS PLAN_ERROR)",  // parity:decision-nested-key-nil
        decisionTag(AgentDecisionParser.parse("""{"thought":{"tool":"delete","input":"all files"},"other":"x"}""")) == "nil")
    check("parity: decision parser rejects non-JSON",  // parity:decision-non-json-nil
        decisionTag(AgentDecisionParser.parse("no json here")) == "nil")
    check("parity: a plan array parses to a plan decision",  // parity:decision-plan-calls
        decisionTag(AgentDecisionParser.parse("""{"plan":[{"tool":"fs.move","input":"a.txt to Archive"},{"tool":"fs.move","input":"b.txt to Archive"}]}""")) == "plan:2:fs.move")
    check("parity: one tool-less item invalidates the WHOLE plan",  // parity:decision-plan-invalid-item
        decisionTag(AgentDecisionParser.parse("""{"plan":[{"tool":"fs.move","input":"a to B"},{"input":"orphan"}]}""")) == "nil")
    check("parity: answer takes precedence over plan",  // parity:decision-plan-answer-precedence
        decisionTag(AgentDecisionParser.parse("""{"answer":"done","plan":[{"tool":"echo","input":"x"}]}""")) == "answer:done")
    // Input is a regular string with `\\u` so it carries the LITERAL 6-char escape the model emits;
    // the expected uses `\u` (compiler-decoded to é / ☺), pinning the decode without typed-accent
    // ambiguity. Was mangled to "cafu00e9" before the unescaper learned \u (iOS's JSON always did this).
    check("parity: decision parser decodes \\uXXXX escapes like iOS",  // parity:decision-unicode-escape
        AgentDecisionParser.parse("{\"answer\":\"caf\\u00e9 \\u263a\"}") == AgentDecision.FinalAnswer("café ☺"))
    check("parity: decision parser still decodes short escapes (\\n \\t)",  // parity:decision-short-escape
        AgentDecisionParser.parse("{\"answer\":\"a\\tb\\nc\"}") == AgentDecision.FinalAnswer("a\tb\nc"))
    check("parity: M9 word boundaries don't false-block",  // parity:blocklist-safe-substrings
        listOf("please repay the favor", "in my opinion", "the company went bankrupt").none { SafetyBlocklist.isBlocked(it) })
    // Java's `\b` is ASCII-only by default, so it saw 'é' as a boundary and fired "pin" on "piné" /
    // "épin" — which iOS's ICU `\b` never did. The (?U) flag makes them agree (accented text = word char).
    check("parity: Unicode word boundary — accented-adjacent text doesn't false-block (iOS ICU parity)",  // parity:blocklist-unicode-boundary
        listOf("piné", "épin").none { SafetyBlocklist.isBlocked(it) })
    check("parity: genuine dangerous actions still blocked",  // parity:blocklist-dangerous
        listOf("tap Pay to continue", "send money now", "delete the file", "enter your pin").all { SafetyBlocklist.isBlocked(it) })

    // --- ModelRouter classification parity (twin of iOS RouterParityTests; ids in
    //     shared/router-parity-vectors.json, bijection enforced by scripts/check_router_parity.py) ---
    fun task(p: String) = "task:" + ModelRouter.classify(p).name.lowercase()
    check("router parity: code fence classifies as coding",  // parity:router-coding-fence
        task("```python\nprint(1)\n```") == "task:coding")
    check("router parity: sql/exception keywords classify as coding",  // parity:router-coding-keyword
        task("Why does my SQL query throw an exception?") == "task:coding")
    check("router parity: coding beats multilingual (Chinese coding question)",  // parity:router-coding-beats-multilingual
        task("用Python写一个函数") == "task:coding")
    check("router parity: step by step classifies as reasoning",  // parity:router-reasoning-step-by-step
        task("Solve this puzzle step by step") == "task:reasoning")
    check("router parity: riddle classifies as reasoning",  // parity:router-reasoning-riddle
        task("Here is a riddle for you") == "task:reasoning")
    check("router parity: CJK classifies as multilingual",  // parity:router-multilingual-cjk
        task("给我讲一个关于森林的故事") == "task:multilingual")
    check("router parity: Cyrillic classifies as multilingual",  // parity:router-multilingual-cyrillic
        task("Расскажи сказку про лес") == "task:multilingual")
    check("router parity: explicit translate marker classifies as multilingual",  // parity:router-multilingual-translate
        task("Translate this sentence into English please") == "task:multilingual")
    check("router parity: accented Latin stays general (threshold counts > 0x24F only)",  // parity:router-accented-latin-general
        task("Où est la bibliothèque? Merci beaucoup") == "task:general")
    check("router parity: no markers classifies as general",  // parity:router-general
        task("What should I cook tonight?") == "task:general")
    check("router picks the coder family for code and falls back when RAM is tight", run {
        val coder = ModelRouter.route("debug this python function", ModelCatalog.models, 16.0, 12.0)
        val tight = ModelRouter.route("debug this python function", ModelCatalog.models, 4.0, 2.5)
        coder != null && coder.modelId.startsWith("qwen25-coder") &&
            tight != null && !tight.modelId.startsWith("qwen25-coder") && ModelRouter.route("hi", emptyList(), 16.0, 8.0) == null
    })

    // --- DegenerationGuard (twin of iOS DegenerationGuardTests) ---
    run {
        val para = "Quender was a forest elf, a member of the slender and agile forest elves."
        val wall = "Once upon a time.\n\n" + List(4) { para }.joinToString("\n\n")
        check("degeneration guard collapses runs of identical substantial paragraphs",
            DegenerationGuard.collapseRepeatedParagraphs(wall) == "Once upon a time.\n\n" + para)
        check("degeneration guard keeps distinct paragraphs and short repeats",
            DegenerationGuard.collapseRepeatedParagraphs("A tale.\n\nYes.\n\nYes.\n\nThe end.") == "A tale.\n\nYes.\n\nYes.\n\nThe end." &&
            DegenerationGuard.collapseRepeatedParagraphs("First idea here.\n\nSecond idea here.") == "First idea here.\n\nSecond idea here.")
        val loop = List(8) { para }.joinToString(" ")
        check("degeneration guard detects a verbatim-looping tail and not normal prose",
            DegenerationGuard.looksDegenerate(loop) && !DegenerationGuard.looksDegenerate(
                "The forest was a vast and varied tapestry of life, where a variety of animals and plants could be found, and every day brought a different weather, a different visitor, and a different small problem to solve."))
    }

    // --- Inference seam (mock) ---
    val engine = MockInferenceEngine(cannedReply = "one two three")
    engine.load(ModelCatalog.smallest, "/dev/null")
    check("mock engine reports the loaded model", engine.loadedModelId == "llama32-1b-q2")
    check("mock engine completes a prompt", engine.complete("hi") == "one two three")
    engine.unload()
    check("unload clears the loaded model", engine.loadedModelId == null)

    // --- LlamaEngine: fails cleanly off-device (no .so), per the JNI contract ---
    val llama = LlamaEngine()
    check("LlamaEngine reports unavailable on the JVM (no native lib)", !llama.available())
    check("LlamaEngine.load throws a clear 'not linked' error when unlinked",
        runCatching { llama.load(ModelCatalog.smallest, "/dev/null") }
            .exceptionOrNull()?.message?.contains("not linked") == true)
    check("LlamaEngine.complete throws when unlinked", runCatching { llama.complete("hi") }.isFailure)
    // recommendedThreads() is the JNI-polled hook that lets a long generation shed threads as the
    // SoC heats (jni/llama_generate.h's thermalPoll — was previously applied only once, at load).
    // Off-device loadedBaseThreads stays at its default (1), so a hot level can't recommend MORE
    // threads than the (never-loaded) baseline — this pins that it degrades safely, not just "compiles".
    check("LlamaEngine.recommendedThreads reflects live thermalLevel against the load-time baseline", run {
        val e = LlamaEngine()
        val nominal = e.recommendedThreads()
        e.thermalLevel = ThermalLevel.CRITICAL
        val critical = e.recommendedThreads()
        nominal == 1 && critical == 1   // baseline is 1 pre-load; CRITICAL can't drop below the floor of 1
    })

    // --- OnboardingModel (M1): probe → recommend → download(mock) → load(mock) → ready ---
    val phases = mutableListOf<OnboardingPhase>()
    val onboarding = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        .apply { onChange = { phases += it } }
    onboarding.start { DeviceProfile(totalRamGB = 8.0, freeRamGB = 6.0) }
    check("onboarding recommends Qwen3 4B for an 8 GB device",
        (onboarding.phase as? OnboardingPhase.Recommended)?.model?.id == "qwen3-4b")
    onboarding.acceptAndPrepare(ModelRecommender.recommendedModel(8.0))
    check("onboarding reaches Ready", onboarding.phase is OnboardingPhase.Ready)
    check("onboarding streamed Downloading progress", phases.any { it is OnboardingPhase.Downloading })
    check("onboarding fails cleanly when even the recommended model can't fit", run {
        val tight = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        tight.start { DeviceProfile(totalRamGB = 2.0, freeRamGB = 0.2) }
        tight.phase is OnboardingPhase.Failed
    })
    check("a failed model switch restores the previously-working model (H1)", run {
        val a = ModelCatalog.models[0]
        val b = ModelCatalog.models.first { it.id != a.id }
        // Engine that loads anything except b, which throws — exercises failed-switch recovery.
        val engine = object : InferenceEngine {
            override var loadedModelId: String? = null
            override fun load(model: ModelEntry, filePath: String) {
                if (model.id == b.id) throw RuntimeException("test: too big to load")
                loadedModelId = model.id
            }
            override fun unload() { loadedModelId = null }
            override fun complete(prompt: String): String = "ok"
        }
        val onb = OnboardingModel(engine, MockModelDownloader())
        onb.acceptAndPrepare(a)   // A loads fine
        onb.acceptAndPrepare(b)   // switch to B fails → must restore A, not strand the user
        val phase = onb.phase
        phase is OnboardingPhase.Ready && phase.model.id == a.id && engine.loadedModelId == a.id
    })
    // Twin of Swift testInstallRemembersModelAndStartRestoresItOnRelaunch: a successful load
    // persists the model id, and a fresh OnboardingModel ("relaunch") restores it straight to
    // Ready — never replaying the first-run recommendation screen.
    check("acceptAndPrepare remembers the model id for the next launch", run {
        var remembered: String? = null
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader(),
            rememberActiveModelID = { remembered = it })
        onb.acceptAndPrepare(ModelCatalog.smallest)
        remembered == ModelCatalog.smallest.id
    })
    check("cold relaunch restores the remembered model straight to Ready — no onboarding replay", run {
        val replayed = mutableListOf<OnboardingPhase>()
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader(),
            recallActiveModelID = { ModelCatalog.smallest.id },
            activeModelFileExists = { true })
        onb.onChange = { replayed += it }
        val restored = onb.restoreAtLaunch()
        val phase = onb.phase
        restored && phase is OnboardingPhase.Ready && phase.model.id == ModelCatalog.smallest.id &&
            replayed.none { it is OnboardingPhase.Recommended }
    })
    check("relaunch restore declines when the remembered file is gone", run {
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader(),
            recallActiveModelID = { ModelCatalog.smallest.id },
            activeModelFileExists = { false })
        !onb.restoreAtLaunch() && onb.phase is OnboardingPhase.Idle
    })
    check("unsupported device: even the smallest model can't run → UNSUPPORTED + Failed onboarding", run {
        // Almost no native-heap budget — even the smallest model won't fit.
        val tiny = AndroidDeviceProfile("Ancient", AndroidSoc.MIDRANGE, 1.0, 0.2, 128.0, 4500.0)
        val sel = AndroidModelSelector.select(tiny)
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        onb.start(tiny)
        sel.confidence == SelectionConfidence.UNSUPPORTED && onb.phase is OnboardingPhase.Failed
    })

    // --- Q-271 (twin of Swift): the LIVE onboarding download honors DownloadPolicy, not just the checklist ---
    check("Q-271: onboarding blocks a cellular download under Wi-Fi-only — engine untouched, reason surfaced", run {
        var downloads = 0
        val downloader = object : ModelDownloader {
            override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String { downloads++; return "/dev/null" }
        }
        val onb = OnboardingModel(MockInferenceEngine(), downloader,
            networkStatus = { NetworkStatus.CELLULAR }, downloadPolicy = { DownloadPolicy.WIFI_ONLY })
        onb.acceptAndPrepare(ModelCatalog.smallest)
        val ph = onb.phase
        downloads == 0 && ph is OnboardingPhase.Failed && ph.reason.contains("Wi-Fi")
    })
    check("Q-271: onboarding proceeds on cellular when the user has permitted it", run {
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader(),
            networkStatus = { NetworkStatus.CELLULAR }, downloadPolicy = { DownloadPolicy.WIFI_OR_CELLULAR })
        onb.acceptAndPrepare(ModelCatalog.smallest)
        onb.phase is OnboardingPhase.Ready
    })
    // Q-336: a re-entrant acceptAndPrepare (here fired from the progress callback via onChange) must be
    // ignored so a double-tap / picker overlap can't run two downloads+loads racing phase and the engine.
    check("Q-336: a re-entrant acceptAndPrepare is ignored — exactly one download runs", run {
        var downloads = 0
        lateinit var onb: OnboardingModel
        val downloader = object : ModelDownloader {
            override fun download(model: ModelEntry, onProgress: (Double) -> Unit): String {
                downloads++
                onProgress(0.5)   // drives a Downloading phase → onChange → the re-entrant call below
                return "/dev/null"
            }
        }
        onb = OnboardingModel(MockInferenceEngine(), downloader)
        onb.onChange = { ph -> if (ph is OnboardingPhase.Downloading) onb.acceptAndPrepare(ModelCatalog.smallest) }
        onb.acceptAndPrepare(ModelCatalog.smallest)
        downloads == 1 && onb.phase is OnboardingPhase.Ready
    })

    // --- ChatModel (M2): send runs the engine, transcript accumulates ---
    val chatEngine = MockInferenceEngine(cannedReply = "Running on-device.")
    chatEngine.load(ModelCatalog.smallest, "/dev/null")
    val sizes = mutableListOf<Int>()
    val chat = ChatModel(chatEngine).apply { onChange = { sizes += it.size } }
    val reply = chat.send("hello")
    check("chat returns the engine reply", reply == "Running on-device.")
    check("chat transcript is user then assistant",
        chat.messages.map { it.role } == listOf(Role.USER, Role.ASSISTANT))
    // send() now streams into a placeholder: emit after the user msg (1), after the assistant
    // placeholder is appended (2), then after it settles to the final text (2). A real streaming
    // engine adds one emit per token in between; the mock (non-streaming fallback) does not.
    check("chat emits user, assistant placeholder, then settle", sizes == listOf(1, 2, 2))
    check("chat rejects an empty message", runCatching { chat.send("   ") }.isFailure)

    // --- ConversationContext (chat memory + context-window budgeting; twin of Swift) ---
    check("conversation context keeps multi-turn history (no amnesia)", run {
        val p = ConversationContext().build(
            listOf(
                ChatMessage(Role.USER, "remember apples"),
                ChatMessage(Role.ASSISTANT, "ok"),
                ChatMessage(Role.USER, "what did I say?"),
            )
        )
        p.contains("remember apples") && p.contains("ok") && p.contains("what did I say?")
    })
    check("conversation context leads with the system prompt + ends primed for the assistant", run {
        val p = ConversationContext().build(listOf(ChatMessage(Role.USER, "hi")))
        p.contains("Quenderin") && p.trimEnd().endsWith("Assistant:")
    })
    check("conversation context drops oldest turns past the token budget, keeps newest", run {
        val ctx = ConversationContext(systemPrompt = "", contextTokens = 80, reservedForResponse = 0)
        val history = (1..20).map {
            ChatMessage(if (it % 2 == 1) Role.USER else Role.ASSISTANT, "message number $it here")
        }
        val p = ctx.build(history)
        !p.contains("message number 1 here") && p.contains("message number 20 here")
    })
    check("conversation context never drops the latest turn even if it alone exceeds budget", run {
        val ctx = ConversationContext(systemPrompt = "", contextTokens = 4, reservedForResponse = 0)
        ctx.build(listOf(ChatMessage(Role.USER, "a single message far larger than the tiny budget")))
            .contains("a single message far larger")
    })
    check("ChatModel feeds prior history back to the engine (memory, not amnesia)", run {
        val captured = mutableListOf<String>()
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "cap"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String { captured += prompt; return "ok" }
        }
        val chat = ChatModel(engine)
        chat.send("remember apples")
        chat.send("recall?")
        captured.last().contains("remember apples") && captured.last().contains("ok")
    })

    // --- ConversationStore (offline persistence: a transcript survives relaunch; twin of Swift) ---
    check("conversation store round-trips roles, text, and order", run {
        val store = ConversationStore()
        val original = listOf(
            ChatMessage(Role.USER, "hi"),
            ChatMessage(Role.ASSISTANT, "hello there"),
            ChatMessage(Role.USER, "bye"),
        )
        val restored = store.decode(store.encode(original))
        restored.map { it.role } == original.map { it.role } && restored.map { it.text } == original.map { it.text }
    })
    check("conversation store decodes blank input to an empty conversation", run {
        ConversationStore().decode("").isEmpty() && ConversationStore().decode("   ").isEmpty()
    })
    check("conversation store survives newlines, tabs, and backslashes in message text", run {
        val store = ConversationStore()
        val tricky = listOf(
            ChatMessage(Role.USER, "line one\nline two\twith tab"),
            ChatMessage(Role.ASSISTANT, "back\\slash and \"quotes\""),
        )
        store.decode(store.encode(tricky)).map { it.text } == tricky.map { it.text }
    })
    check("ChatModel.restore seeds a saved transcript", run {
        val chat = ChatModel(MockInferenceEngine())
        chat.restore(listOf(ChatMessage(Role.USER, "earlier question"), ChatMessage(Role.ASSISTANT, "earlier answer")))
        chat.messages.size == 2 && chat.messages.first().text == "earlier question"
    })

    // --- ConversationLibrary (chat-history index: recency list / upsert / remove / title; twin of Swift) ---
    check("conversation library lists most-recent-first with a stable id tie-break", run {
        val lib = ConversationLibrary()
        lib.upsert(ConversationSummary("a", "A", 100))
        lib.upsert(ConversationSummary("c", "C", 300))
        lib.upsert(ConversationSummary("b", "B", 300))
        lib.list().map { it.id } == listOf("b", "c", "a")
    })
    check("conversation library upsert replaces by id", run {
        val lib = ConversationLibrary()
        lib.upsert(ConversationSummary("a", "first", 100))
        lib.upsert(ConversationSummary("a", "renamed", 200))
        lib.count == 1 && lib.get("a")?.title == "renamed" && lib.get("a")?.updatedAt == 200L
    })
    check("conversation library remove + snapshot/restore round-trip", run {
        val lib = ConversationLibrary()
        lib.upsert(ConversationSummary("a", "A", 1))
        lib.upsert(ConversationSummary("b", "B", 2))
        lib.remove("a") && ConversationLibrary(lib.snapshot()).list().map { it.id } == listOf("b")
    })
    check("conversation library derives a title from the first user message", run {
        ConversationLibrary.titleFromFirstUserMessage(null) == "New conversation" &&
            ConversationLibrary.titleFromFirstUserMessage("  hello   there  ") == "hello there" &&
            ConversationLibrary.titleFromFirstUserMessage("x".repeat(60)).let { it.length == 41 && it.endsWith("…") }
    })
    // Truncation is by CODE POINT → an emoji title cuts at the same point as iOS's scalar-based cut
    // (cross-platform parity) and never leaves a lone surrogate.
    check("conversation title truncates by code point (emoji parity with iOS)", run {
        ConversationLibrary.titleFromFirstUserMessage("😀" + "a".repeat(45)) == "😀" + "a".repeat(39) + "…"
    })

    // --- ConversationManager (capstone: lifecycle over library + persistence; twin of Swift) ---
    check("conversation manager startNew defers the index row until first save (WhatsApp rule)", run {
        val p = InMemoryConversationPersistence()
        val mgr = ConversationManager(p, now = { 1000L }, makeId = { "c1" })
        val id = mgr.startNew()
        val nothingWritten = mgr.currentId == id && mgr.list().isEmpty() && p.loadIndex().isEmpty()
        mgr.save(id, listOf(ChatMessage(Role.USER, "hi")))
        nothingWritten && mgr.list().map { it.id } == listOf(id)
    })
    check("conversation manager pruneEmptyConversations drops blank shells, keeps real ones", run {
        val p = InMemoryConversationPersistence()
        // A legacy index as the old create-immediately startNew() wrote it: one real conversation
        // plus abandoned "New conversation" shells (one with an empty transcript, one with none).
        p.saveTranscript("real", listOf(ChatMessage(Role.USER, "keep me")))
        p.saveTranscript("blank1", emptyList())
        p.saveIndex(listOf(
            ConversationSummary("real", "keep me", 1),
            ConversationSummary("blank1", "New conversation", 2),
            ConversationSummary("blank2", "New conversation", 3),
        ))
        val mgr = ConversationManager(p, now = { 9L }, makeId = { "x" })
        mgr.pruneEmptyConversations()
        mgr.list().map { it.id } == listOf("real") && p.loadIndex().map { it.id } == listOf("real")
    })
    check("conversation manager save derives a title and persists the transcript", run {
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { 1000L }, makeId = { "c1" })
        val id = mgr.startNew()
        mgr.save(id, listOf(ChatMessage(Role.USER, "How do I center a div?"), ChatMessage(Role.ASSISTANT, "Flexbox.")))
        mgr.list().first().title == "How do I center a div?" && mgr.open(id).size == 2
    })
    check("conversation manager lists newest-first and a touch re-sorts to top", run {
        var clock = 1000L
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { clock }, makeId = { "id-$clock" })
        val first = mgr.startNew()
        mgr.save(first, listOf(ChatMessage(Role.USER, "first"))); clock += 1000
        val second = mgr.startNew()
        mgr.save(second, listOf(ChatMessage(Role.USER, "second")))
        val newestIsSecond = mgr.list().first().id == second
        clock += 1000
        mgr.save(first, listOf(ChatMessage(Role.USER, "first"), ChatMessage(Role.ASSISTANT, "reply")))
        newestIsSecond && mgr.list().first().id == first
    })
    check("conversation manager delete removes everywhere and clears current", run {
        val mgr = ConversationManager(InMemoryConversationPersistence(), now = { 1L }, makeId = { "c1" })
        val id = mgr.startNew()
        mgr.save(id, listOf(ChatMessage(Role.USER, "hi")))
        mgr.delete(id)
        mgr.list().isEmpty() && mgr.currentId == null && mgr.open(id).isEmpty()
    })
    check("conversation manager history survives a fresh instance (persistence-backed)", run {
        val p = InMemoryConversationPersistence()
        val id = ConversationManager(p, now = { 5L }, makeId = { "c1" }).let { m -> m.startNew().also { m.save(it, listOf(ChatMessage(Role.USER, "remembered question"))) } }
        val reopened = ConversationManager(p, now = { 9L }, makeId = { "x" })
        reopened.list().map { it.id } == listOf(id) && reopened.open(id).size == 1 &&
            reopened.list().first().title == "remembered question"
    })

    // --- ModelManager (multi-model lifecycle: installed / active / usage / delete; twin of Swift) ---
    run {
        val small = ModelCatalog.smallest
        val mid = ModelCatalog.entry("qwen3-4b")!!
        fun storage() = InMemoryModelStorage().apply { install(small.filename, 300); install(mid.filename, 4000) }

        check("model manager lists only on-disk catalog models with sizes + total usage", run {
            val mgr = ModelManager(storage())
            mgr.installed().map { it.id }.toSet() == setOf(small.id, mid.id) && mgr.totalBytesUsed == 4300L
        })
        check("model manager pins the active model to the top and rejects activating an uninstalled one", run {
            val mgr = ModelManager(storage())
            mgr.setActive(small.id) && mgr.installed().first().id == small.id && !mgr.setActive("nope")
        })
        check("model manager delete reclaims bytes and clears active when the active model is removed", run {
            val mgr = ModelManager(storage(), initialActiveModelId = mid.id)
            val reclaimableOk = mgr.reclaimableBytes == 300L
            val freed = mgr.delete(mid.id)
            reclaimableOk && freed == 4000L && mgr.activeModelId == null && !mgr.isInstalled(mid.id) && mgr.totalBytesUsed == 300L
        })
        check("model manager delete of an uninstalled model is a no-op", run {
            val mgr = ModelManager(InMemoryModelStorage().apply { install(small.filename, 300) })
            mgr.delete("qwen3-14b") == 0L && mgr.totalBytesUsed == 300L
        })
        // The real File-backed storage the app uses (twin of Swift FileManagerModelStorageTests).
        check("FileModelStorage reads real on-disk sizes, lists models, and deletes", run {
            val dir = java.nio.file.Files.createTempDirectory("models").toFile()
            try {
                java.io.File(dir, small.filename).writeBytes(ByteArray(300))
                java.io.File(dir, mid.filename).writeBytes(ByteArray(4000))
                java.io.File(dir, ".hidden").writeBytes(ByteArray(9))   // ignored
                val mgr = ModelManager(FileModelStorage(dir), initialActiveModelId = mid.id)
                val listed = mgr.installed().map { it.id }.toSet() == setOf(small.id, mid.id)
                val preTotal = mgr.totalBytesUsed == 4300L      // both files, before any delete
                val preReclaim = mgr.reclaimableBytes == 300L   // only the non-active small is reclaimable
                val freed = mgr.delete(small.id)
                val postDelete = freed == 300L && !java.io.File(dir, small.filename).exists() && mgr.totalBytesUsed == 4000L
                listed && preTotal && preReclaim && postDelete
            } finally {
                dir.deleteRecursively()
            }
        })
    }

    // --- KVCacheReuse (incremental decode planning; twin of Swift; the JNI loop mirrors this spec) ---
    check("KVCacheReuse: append keeps the cache, first turn / identical / shrank reprefill", run {
        val append = KVCacheReuse.plan(intArrayOf(1, 2, 3), intArrayOf(1, 2, 3, 4, 5))
        val first = KVCacheReuse.plan(intArrayOf(), intArrayOf(1, 2, 3))
        val identical = KVCacheReuse.plan(intArrayOf(1, 2, 3), intArrayOf(1, 2, 3))   // not STRICT prefix
        val shrank = KVCacheReuse.plan(intArrayOf(1, 2, 3, 4), intArrayOf(1, 2))       // new is a prefix of cached
        append == KVCacheReuse.Plan(false, 3, 0, 0) && first == KVCacheReuse.Plan(true, 0, 0, 0) &&
            identical == KVCacheReuse.Plan(true, 0, 0, 0) && shrank == KVCacheReuse.Plan(true, 0, 0, 0)
    })
    check("KVCacheReuse: context-shift reuses the surviving tail after the oldest turn is dropped", run {
        // system=[1,2], dropped turn=[3,4], surviving turns=[5,6,7], new turn appended=[8].
        // cache = system+dropped+surviving; new = system+surviving+newturn.
        val cached = intArrayOf(1, 2, 3, 4, 5, 6, 7)
        val new = intArrayOf(1, 2, 5, 6, 7, 8)
        val plan = KVCacheReuse.plan(cached, new)
        // Evict cache positions [2,4) (the dropped turn), shift survivors [5,6,7] down by 2, decode only new[5:]=[8].
        // Reuses 5 of 6 tokens instead of the old behaviour (full reprefill of all 6).
        plan == KVCacheReuse.Plan(false, 5, 2, 4)
    })
    check("KVCacheReuse: picks the SMALLEST gap (maximal reuse) when several tails align", run {
        // After prefix [1,8], dropping g=1 ([8]) realigns the tail [2,2]; dropping g=2 ([8,2]) also
        // realigns ([2]) but reuses less. The plan must take the smaller gap (more tokens kept).
        val cached = intArrayOf(1, 8, 8, 2, 2)
        val new = intArrayOf(1, 8, 2, 2, 9)
        val plan = KVCacheReuse.plan(cached, new)
        // p=2 ([1,8]), evict [2,3) (one [8]), shift [2,2] down, decode new[4:]=[9]; reuses 4 of 5.
        plan == KVCacheReuse.Plan(false, 4, 2, 3) && simulateReuse(cached, new, plan)?.toList() == new.toList()
    })
    check("KVCacheReuse: falls back to prefix-only reuse when no tail aligns", run {
        // Only the leading [1,2] survives; the rest of the cache diverges with no realignable tail.
        val cached = intArrayOf(1, 2, 3, 4)
        val new = intArrayOf(1, 2, 8, 9, 10)
        val plan = KVCacheReuse.plan(cached, new)
        // Keep prefix [0,2), evict [2,4), decode new[2:] — better than a full reprefill (saves the prefix).
        plan == KVCacheReuse.Plan(false, 2, 2, 4)
    })
    check("KVCacheReuse: a changed system prompt (no common prefix) still fully reprefills", run {
        val plan = KVCacheReuse.plan(intArrayOf(1, 2, 3, 4), intArrayOf(9, 2, 3, 4, 5))
        plan == KVCacheReuse.Plan(true, 0, 0, 0)   // p==0 → nothing to reuse
    })
    check("KVCacheReuse: context-shift result reconstructs the new prompt exactly (invariant)", run {
        // Simulate the native executor purely on the token mirror and assert cache == new afterward.
        val cached = intArrayOf(10, 11, 20, 21, 22, 30, 31, 32, 33)  // sys[10,11] + drop[20,21,22] + keep[30,31,32,33]
        val new = intArrayOf(10, 11, 30, 31, 32, 33, 40)             // sys + keep + newturn[40]
        val plan = KVCacheReuse.plan(cached, new)
        val simulated = simulateReuse(cached, new, plan)
        simulated != null && simulated.toList() == new.toList()
    })

    // --- ConversationExporter (transcript → portable markdown; twin of Swift) ---
    check("ConversationExporter renders a markdown transcript with speakers + plural count", run {
        val md = ConversationExporter.markdown(
            listOf(ChatMessage(Role.USER, "Hello there"), ChatMessage(Role.ASSISTANT, "Hi!")),
            "My chat",
        )
        md.startsWith("# My chat\n") && md.contains("**You:**\nHello there") &&
            md.contains("**Quenderin:**\nHi!") && md.contains("2 messages")
    })
    check("ConversationExporter falls back to default title + singular count, no empty speakers", run {
        val one = ConversationExporter.markdown(listOf(ChatMessage(Role.USER, "Only one")), null)
        val none = ConversationExporter.markdown(emptyList(), "  ")
        one.startsWith("# Conversation\n") && one.contains("1 message.") &&
            none.startsWith("# Conversation\n") && none.contains("0 messages") && !none.contains("**You:**")
    })

    // --- AgentRunExporter (agent run → portable markdown walkthrough; twin of Swift) ---
    check("AgentRunExporter renders steps + answer for an answered run", run {
        val r = AgentRun(
            listOf(
                AgentStep(AgentDecision.UseTool("calculator", "2+2"), "4"),
                AgentStep(AgentDecision.FinalAnswer("The answer is 4."), null),
            ),
            "The answer is 4.",
            AgentRun.HaltReason.ANSWERED,
        )
        val md = AgentRunExporter.markdown(r, "What is 2+2?")
        md.contains("# Agent walkthrough: What is 2+2?") && md.contains("2 steps") &&
            // Glanceable verification summary up top — outcome + tools used (identical to iOS twin).
            md.contains("**Outcome: answered.** Tools used: calculator.") &&
            md.contains("**1. Used `calculator`(2+2)** → 4") && md.contains("**2. Final answer**") &&
            md.contains("**Answer:** The answer is 4.") && !md.contains("Halted:")
    })
    check("AgentRunExporter shows the halt reason (not an answer) when the agent didn't finish", run {
        val r = AgentRun(listOf(AgentStep(AgentDecision.UseTool("echo", "hi"), "hi")), null, AgentRun.HaltReason.MAX_STEPS)
        val md = AgentRunExporter.markdown(r, "")
        md.contains("# Agent walkthrough: Agent run") && md.contains("1 step.") &&
            md.contains("**Outcome: stopped at the step limit.** Tools used: echo.") &&
            md.contains("**Halted:** The agent reached its step limit") && !md.contains("**Answer:**")
    })
    check("AgentRunExporter summary reports 'No tools used' for a direct answer + dedups repeated tools", run {
        val direct = AgentRun(listOf(AgentStep(AgentDecision.FinalAnswer("Paris."), null)), "Paris.", AgentRun.HaltReason.ANSWERED)
        val repeated = AgentRun(
            listOf(
                AgentStep(AgentDecision.UseTool("calculator", "2+2"), "4"),
                AgentStep(AgentDecision.UseTool("calculator", "4*4"), "16"),
                AgentStep(AgentDecision.FinalAnswer("Done."), null),
            ),
            "Done.", AgentRun.HaltReason.ANSWERED,
        )
        AgentRunExporter.markdown(direct, "Capital of France?").contains("**Outcome: answered.** No tools used.") &&
            AgentRunExporter.markdown(repeated, "math").contains("**Outcome: answered.** Tools used: calculator.")
    })

    // --- Android SoC resolution + native-heap memory model ---
    check("resolves Snapdragon 8 Gen 3", AndroidSoc.fromSocModel("SM8650") == AndroidSoc.SNAPDRAGON_8_GEN_3)
    check("resolves Dimensity 9300", AndroidSoc.fromSocModel("MT6989") == AndroidSoc.DIMENSITY_9300)
    check("unknown SoC falls back", AndroidSoc.fromSocModel("mystery-chip") == AndroidSoc.UNKNOWN)
    check("native budget below total RAM but generous", run {
        val b = AndroidSoc.nativeMemoryBudgetGB(8.0); b < 8.0 && b > 5.0
    })
    check("Android handles 16 GB tiers no iPhone has", AndroidSoc.nativeMemoryBudgetGB(16.0) >= 11.0)

    // --- GPU offload (Vulkan) planner: safe-by-default, device-aware ---
    check("GPU: a CPU-only build never offloads, whatever the SoC",
        GpuOffloadPlanner.recommend(AndroidSoc.SNAPDRAGON_8_ELITE, vulkanAvailable = false) == GpuOffloadPlanner.CPU_ONLY)
    check("GPU: Adreno (Snapdragon, incl. the S23's 8 Gen 2) offloads all layers when Vulkan is built",
        GpuOffloadPlanner.recommend(AndroidSoc.SNAPDRAGON_8_GEN_2, vulkanAvailable = true) == GpuOffloadPlanner.ALL_LAYERS &&
        GpuOffloadPlanner.gpuClass(AndroidSoc.SNAPDRAGON_8_GEN_2) == GpuOffloadPlanner.GpuClass.ADRENO)
    check("GPU: Mali (Dimensity/Tensor) stays on CPU until benchmarked",
        GpuOffloadPlanner.recommend(AndroidSoc.DIMENSITY_9300, vulkanAvailable = true) == GpuOffloadPlanner.CPU_ONLY &&
        GpuOffloadPlanner.recommend(AndroidSoc.TENSOR_G4, vulkanAvailable = true) == GpuOffloadPlanner.CPU_ONLY)
    check("GPU: unknown/Xclipse SoCs stay on CPU (conservative)",
        GpuOffloadPlanner.recommend(AndroidSoc.UNKNOWN, vulkanAvailable = true) == GpuOffloadPlanner.CPU_ONLY &&
        GpuOffloadPlanner.recommend(AndroidSoc.EXYNOS_2400, vulkanAvailable = true) == GpuOffloadPlanner.CPU_ONLY)
    check("GPU: forceGpu override offloads an untrusted GPU (for benchmarking) — but not without a Vulkan build",
        GpuOffloadPlanner.recommend(AndroidSoc.DIMENSITY_9400, vulkanAvailable = true, forceGpu = true) == GpuOffloadPlanner.ALL_LAYERS &&
        GpuOffloadPlanner.recommend(AndroidSoc.DIMENSITY_9400, vulkanAvailable = false, forceGpu = true) == GpuOffloadPlanner.CPU_ONLY)

    // --- Android model selector: device-aware, jetsam-free picks ---
    fun androidProfile(name: String, soc: AndroidSoc, ram: Double) =
        AndroidDeviceProfile(name, soc, ram, AndroidSoc.nativeMemoryBudgetGB(ram), freeDiskGb = 128.0, batteryMAh = 4500.0)

    check("4 GB mid-range Android → 1B",
        AndroidModelSelector.select(androidProfile("Budget", AndroidSoc.MIDRANGE, 4.0)).model.id == "llama32-1b")
    check("6 GB Snapdragon 8 Gen 2 → 4B",
        AndroidModelSelector.select(androidProfile("Mid", AndroidSoc.SNAPDRAGON_8_GEN_2, 6.0)).model.id == "qwen3-4b")
    check("8 GB Snapdragon 8 Gen 3 → 4B, 7B offered", run {
        val sel = AndroidModelSelector.select(androidProfile("Flagship", AndroidSoc.SNAPDRAGON_8_GEN_3, 8.0))
        sel.model.id == "qwen3-4b" && sel.alternatives.any { it.model.id == "mistral-7b" }
    })
    check("16 GB Snapdragon 8 Elite → 7B (RAM no iPhone has unlocks it)",
        AndroidModelSelector.select(androidProfile("Gaming", AndroidSoc.SNAPDRAGON_8_ELITE, 16.0)).model.id == "mistral-7b")
    check("same 12 GB, faster chip picks bigger", run {
        val elite = AndroidModelSelector.select(androidProfile("A", AndroidSoc.SNAPDRAGON_8_ELITE, 12.0)).model.id
        val gen1 = AndroidModelSelector.select(androidProfile("B", AndroidSoc.SNAPDRAGON_8_GEN_1, 12.0)).model.id
        elite == "mistral-7b" && gen1 == "qwen3-4b"
    })
    check("14B never auto-picked on a phone (too slow even at 16 GB)",
        AndroidModelSelector.select(androidProfile("Gaming", AndroidSoc.SNAPDRAGON_8_ELITE, 16.0)).model.id != "qwen3-14b")
    check("Android pick carries a thermal/battery estimate", run {
        val tb = AndroidModelSelector.select(androidProfile("Flagship", AndroidSoc.SNAPDRAGON_8_GEN_3, 8.0)).thermalBattery
        tb.mAhPer1KTokens > 0 && tb.sustainedVerdict.contains("%/hr")
    })
    check("onboarding via AndroidDeviceProfile uses the selector", run {
        val onb = OnboardingModel(MockInferenceEngine(), MockModelDownloader())
        onb.start(AndroidDeviceProfile.from("Flagship", "SM8650", totalRamGb = 8.0, freeDiskGb = 128.0))
        val ph = onb.phase
        ph is OnboardingPhase.Recommended && ph.model.id == "qwen3-4b" && onb.selection != null
    })

    // --- M3 offline-readiness (Android parity with iOS) ---
    check("Wi-Fi-only policy blocks cellular", !DownloadPolicy.WIFI_ONLY.allows(NetworkStatus.CELLULAR))
    check("Wi-Fi-only policy allows Wi-Fi", DownloadPolicy.WIFI_ONLY.allows(NetworkStatus.WIFI))
    check("no connection is always blocked", !DownloadPolicy.WIFI_OR_CELLULAR.allows(NetworkStatus.NONE))
    check("a held-back download explains why", DownloadPolicy.WIFI_ONLY.reason(NetworkStatus.CELLULAR)?.contains("Wi-Fi") == true)
    check("disk check blocks a 4B on a near-full device",
        !DiskSpace.check(ModelCatalog.entry("qwen3-4b")!!, availableBytes = 100L * 1024 * 1024).hasRoom)
    check("disk check passes with ample room",
        DiskSpace.check(ModelCatalog.smallest, availableBytes = 50L * 1024 * 1024 * 1024).hasRoom)
    check("a missing model is not offline-ready",
        !OfflineReadinessChecker.evaluate(ModelCatalog.smallest, fileExists = false, fileSizeBytes = 0).isReadyForOffline)
    check("a complete file IS offline-ready", run {
        val m = ModelCatalog.smallest
        OfflineReadinessChecker.evaluate(m, fileExists = true, fileSizeBytes = DiskSpace.estimatedDownloadBytes(m)).isReadyForOffline
    })
    check("a half-downloaded file reports incomplete %", run {
        val m = ModelCatalog.smallest
        val r = OfflineReadinessChecker.evaluate(m, fileExists = true, fileSizeBytes = DiskSpace.estimatedDownloadBytes(m) / 2)
        !r.isReadyForOffline && r.message.contains("%")
    })

    // --- M4 agent loop (Android parity): plan → safety-gate → execute → observe → repeat ---
    check("arithmetic parser evaluates precedence + parens", ArithmeticParser.evaluate("12 * (3 + 4)") == 84.0)
    check("arithmetic parser rejects malformed input", ArithmeticParser.evaluate("2 +* 3") == null)
    check("arithmetic parser rejects divide-by-zero", ArithmeticParser.evaluate("4 / 0") == null)
    check("calculator renders integers cleanly", CalculatorTool().run("20 + 22") == "42")
    check("calculator: exponent — right-assoc, binds tighter than * /, unary minus looser", run {
        ArithmeticParser.evaluate("2^10") == 1024.0 &&
            ArithmeticParser.evaluate("2^3^2") == 512.0 &&   // right-assoc: 2^(3^2) = 2^9, not (2^3)^2=64
            ArithmeticParser.evaluate("2*3^2") == 18.0 &&    // ^ before *: 2*(3^2)
            ArithmeticParser.evaluate("-2^2") == -4.0 &&     // unary minus looser: -(2^2)
            ArithmeticParser.evaluate("(-2)^2") == 4.0 &&
            ArithmeticParser.evaluate("2^-1") == 0.5 &&      // negative exponent
            CalculatorTool().run("2^10") == "1024"
    })
    check("calculator: non-finite results don't leak (NaN/Inf → couldn't evaluate)",
        ArithmeticParser.evaluate("(-2)^0.5") == null && ArithmeticParser.evaluate("2^9999") == null)
    check("calculator: parity-safe functions + constants (sqrt/abs/floor/ceil, pi/e)", run {
        ArithmeticParser.evaluate("sqrt(16)") == 4.0 && ArithmeticParser.evaluate("abs(-7)") == 7.0 &&
            ArithmeticParser.evaluate("floor(2.7)") == 2.0 && ArithmeticParser.evaluate("ceil(2.1)") == 3.0 &&
            ArithmeticParser.evaluate("floor(pi)") == 3.0 && ArithmeticParser.evaluate("floor(e)") == 2.0 &&
            ArithmeticParser.evaluate("2 * sqrt(9)") == 6.0 && ArithmeticParser.evaluate("sqrt(9) ^ 2") == 9.0 &&
            // sqrt(-1) = NaN rejected; unsupported names (incl. log, which we DON'T add) rejected
            ArithmeticParser.evaluate("sqrt(-1)") == null && ArithmeticParser.evaluate("foo(2)") == null &&
            ArithmeticParser.evaluate("log(10)") == null && CalculatorTool().run("sqrt(16)") == "4"
    })
    check("calculator: modulo (% at the * / level, left-assoc, div-by-zero safe)", run {
        ArithmeticParser.evaluate("10 % 3") == 1.0 &&
            ArithmeticParser.evaluate("2 * 3 % 4") == 2.0 &&   // (2*3)%4 = 6%4 = 2
            ArithmeticParser.evaluate("-10 % 3") == -1.0 &&
            ArithmeticParser.evaluate("10 % 0") == null &&     // modulo by zero rejected
            CalculatorTool().run("10 % 3") == "1"
    })
    check("units converts length", UnitConverterTool().run("1 km to m") == "1 km = 1000 m")
    check("units handles affine temperature", UnitConverterTool().run("30 C to F") == "30 c = 86 f")
    check("units converts time (h/min/day, with spelled-out aliases)", run {
        UnitConverterTool().run("2 hours to minutes") == "2 h = 120 min" &&
            UnitConverterTool().run("90 min to h") == "90 min = 1.5 h" &&
            UnitConverterTool().run("1 day to hours") == "1 day = 24 h"
    })
    check("units rejects cross-dimension time (h vs km)", UnitConverterTool().run("5 h to km").contains("Can't convert"))
    check("units resolves spelled-out aliases", UnitConverterTool().run("5 kilometers to miles").contains("3.10"))
    check("units rejects cross-dimension", UnitConverterTool().run("5 kg to mi").contains("Can't convert"))
    check("units rejects garbage", UnitConverterTool().run("hello world").contains("Couldn't read"))
    check("date counts days between (order-independent)", DateCalcTool().run("days between 2026-12-25 and 2026-06-08") == "200 days")
    check("date adds days across months", DateCalcTool().run("2026-06-08 plus 90 days") == "2026-09-06")
    check("date subtracts days", DateCalcTool().run("2026-12-25 minus 14 days") == "2026-12-11")
    check("date rejects garbage", DateCalcTool().run("what time is it").contains("Couldn't read"))
    check("date: day of the week (deterministic, parity with iOS names)", run {
        DateCalcTool().run("what day of the week is 2026-12-25") == "Friday" &&
            DateCalcTool().run("weekday of 2026-06-08") == "Monday" &&
            DateCalcTool().run("2026-06-08 plus 90 days") == "2026-09-06"   // offset query not hijacked
    })
    // Calendar-invalid dates must be rejected, not silently rolled over (iOS DateFormatter did the
    // latter; round-trip validation now makes it strict too). java.time.LocalDate is strict already.
    check("date rejects calendar-invalid dates (iOS strict parity)",
        DateCalcTool().run("days between 2026-02-30 and 2026-12-25").contains("Couldn't read") &&
        DateCalcTool().run("2026-02-29 plus 1 day").contains("Couldn't read"))
    check("date accepts a real leap day (2024-02-29)",
        DateCalcTool().run("2024-02-29 plus 1 day") == "2024-03-01")
    check("decision parser reads a tool call",
        AgentDecisionParser.parse("""{"tool":"calculator","input":"2+2"}""") == AgentDecision.UseTool("calculator", "2+2"))
    check("decision parser reads a final answer wrapped in prose",
        AgentDecisionParser.parse("""Sure thing! {"answer":"42"} hope that helps""") == AgentDecision.FinalAnswer("42"))
    check("agent loop uses a tool then answers", run {
        val engine = ScriptedInferenceEngine(listOf(
            """{"tool":"calculator","input":"20 + 22"}""",
            """{"answer":"The answer is 42."}""",
        ))
        val r = AgentLoop(engine, listOf(CalculatorTool())).run("What is 20 + 22?")
        r.haltReason == AgentRun.HaltReason.ANSWERED && r.answer == "The answer is 42." && r.steps.any { it.observation == "42" }
    })
    check("agent loop safety-gates a blocked action", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"echo","input":"delete my files and pay"}"""))
        AgentLoop(engine, listOf(EchoTool())).run("do it").haltReason == AgentRun.HaltReason.BLOCKED
    })
    check("agent loop halts planError after CONSECUTIVE non-JSON replies (one nudge first)",
        AgentLoop(ScriptedInferenceEngine(listOf("not json", "still not json")), emptyList()).run("x").haltReason == AgentRun.HaltReason.PLAN_ERROR)
    check("agent loop RECOVERS from a single malformed reply (nudge → proceed)", run {
        val engine = ScriptedInferenceEngine(listOf("oops not json", """{"answer":"recovered"}"""))
        val r = AgentLoop(engine, listOf(EchoTool())).run("x")
        r.haltReason == AgentRun.HaltReason.ANSWERED && r.answer == "recovered"
    })
    check("agent loop caps runaway steps", run {
        // Distinct inputs each step so the runaway isn't a stall — this pins the maxSteps cap itself.
        val engine = ScriptedInferenceEngine(List(10) { """{"tool":"echo","input":"loop$it"}""" })
        AgentLoop(engine, listOf(EchoTool()), maxSteps = 3).run("x").haltReason == AgentRun.HaltReason.MAX_STEPS
    })
    check("agent loop halts STALLED when the model repeats the same action (runs it once)", run {
        val same = """{"tool":"echo","input":"a"}"""
        val r = AgentLoop(ScriptedInferenceEngine(listOf(same, same, same)), listOf(EchoTool()), maxSteps = 6).run("x")
        r.haltReason == AgentRun.HaltReason.STALLED && r.steps.size == 1
    })
    check("Q-641: agent loop halts with CANCELLED at a step boundary (parity with iOS/desktop kill switch)", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"echo","input":"a"}""", """{"tool":"echo","input":"b"}"""))
        val r = AgentLoop(engine, listOf(EchoTool()), maxSteps = 5).run("keep going", isCancelled = { true })
        r.haltReason == AgentRun.HaltReason.CANCELLED && r.steps.isEmpty()
    })
    check("agent loop streams steps live via onStep", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"calculator","input":"1+1"}""", """{"answer":"done"}"""))
        val streamed = mutableListOf<AgentStep>()
        val r = AgentLoop(engine, listOf(CalculatorTool())).run("x") { streamed.add(it) }
        streamed.size == r.steps.size && streamed.size == 2
    })
    check("agent session runs and publishes the result", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"calculator","input":"2+2"}""", """{"answer":"4"}"""))
        var changes = 0
        val session = AgentSession(engine, listOf(CalculatorTool())) { changes++ }
        session.run("2+2?")
        session.answer == "4" && session.steps.size == 2 && !session.isRunning &&
            session.haltReason == AgentRun.HaltReason.ANSWERED && changes > 0
    })
    // End-to-end: the SHIPPED export path (loop → session.run → exportMarkdown → AgentRunExporter),
    // not just the exporter in isolation — catches glue bugs like lastGoal not being stored.
    check("agent session exports the REAL run as a walkthrough (end-to-end)", run {
        val engine = ScriptedInferenceEngine(listOf("""{"tool":"calculator","input":"2+2"}""", """{"answer":"4"}"""))
        val session = AgentSession(engine, listOf(CalculatorTool()))
        val before = session.exportMarkdown()          // nothing run yet → null
        session.run("What is 2+2?")
        val md = session.exportMarkdown()
        before == null && md != null &&
            md.contains("# Agent walkthrough: What is 2+2?") &&   // lastGoal stored + used as heading
            md.contains("`calculator`(2+2)") && md.contains("**Answer:** 4")
    })

    // --- M3 resume bookkeeping (DownloadStore) ---
    check("download store tracks fraction complete", run {
        val store = DownloadStore()
        store.upsert(PersistedDownload("qwen3-4b", "q.gguf", "https://x", "/tmp/q.gguf", totalBytes = 1000))
        store.updateProgress("qwen3-4b", bytesDownloaded = 250, totalBytes = 1000)
        store.get("qwen3-4b")?.fractionComplete == 0.25
    })
    check("paused download resumes from its byte offset", run {
        val d = PersistedDownload("m", "f", "u", "/p", bytesDownloaded = 500, totalBytes = 1000, state = PersistedDownload.State.PAUSED)
        d.resumeOffset == 500L
    })
    check("completed download resumes from 0", run {
        PersistedDownload("m", "f", "u", "/p", 1000, 1000, PersistedDownload.State.COMPLETED).resumeOffset == 0L
    })
    check("download store restores from a snapshot", run {
        val store = DownloadStore()
        store.upsert(PersistedDownload("m", "f", "u", "/p", bytesDownloaded = 300, totalBytes = 900))
        DownloadStore(store.snapshot()).get("m")?.bytesDownloaded == 300L
    })
    check("resumable() returns only in-flight (running/paused) rows", run {
        val store = DownloadStore()
        store.upsert(PersistedDownload("a", "a", "u", "/p", state = PersistedDownload.State.RUNNING))
        store.upsert(PersistedDownload("b", "b", "u", "/p", state = PersistedDownload.State.PAUSED))
        store.upsert(PersistedDownload("c", "c", "u", "/p", state = PersistedDownload.State.COMPLETED))
        store.resumable().map { it.modelId }.toSet() == setOf("a", "b")
    })

    // --- Model integrity (GGUF magic + SHA-256 verification; audit C3) ---
    check("GGUF magic detected on a real header", ModelIntegrity.hasGGUFMagic(ModelIntegrity.GGUF_MAGIC + byteArrayOf(1, 2, 3)))
    check("non-GGUF bytes rejected", !ModelIntegrity.hasGGUFMagic("<htm".toByteArray()))
    check("too-short buffer is not GGUF", !ModelIntegrity.hasGGUFMagic(byteArrayOf(0x47, 0x47)))
    check("sha256 matches the NIST 'abc' test vector",
        ModelIntegrity.sha256Hex("abc".toByteArray()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    // --- Support contact (Generative-AI "report this response" mailto; twin of Swift) ---
    check("report mailto targets the support address", run {
        val uri = SupportContact.reportMailtoUri("hello", "chat")
        uri.startsWith("mailto:${SupportContact.REPORT_EMAIL}?") && uri.contains("subject=") && uri.contains("body=")
    })
    check("report mailto percent-encodes special chars so model output can't break the URI", run {
        val uri = SupportContact.reportMailtoUri("danger & death = bad?", "agent")
        !uri.contains("danger & death") && uri.contains("danger") && !uri.contains(" ")
    })
    check("AI disclaimer is non-empty", SupportContact.AI_DISCLAIMER.isNotEmpty())

    // --- Model download engine (the resumable, pure-Kotlin brain of the WorkManager downloader) ---
    // A 100-byte body starting with the GGUF magic + a catalog entry pinned to its hash, so the
    // engine's integrity gate (C3) passes on the happy paths below.
    val payload = ModelIntegrity.GGUF_MAGIC + ByteArray(96) { (it % 7).toByte() }
    val sampleModel = ModelCatalog.smallest.copy(sha256 = ModelIntegrity.sha256Hex(payload))
    val finalFile = "/models/${sampleModel.filename}"
    val partFile = "$finalFile.part"

    check("fresh download writes the full file, returns its path, finishes at 1.0, clears the store", run {
        val sink = FakeFileSink()
        val store = DownloadStore()
        val engine = ModelDownloadEngine(FakeHttpRangeClient(payload, supportsResume = true), sink, store, "/models")
        var last = 0.0
        val path = engine.download(sampleModel) { last = it }
        sink.files[finalFile]?.size == 100 && path == finalFile && last == 1.0 && store.get(sampleModel.id) == null
    })
    check("an already-complete final file is reused without re-fetching (no double download)", run {
        val sink = FakeFileSink().apply { files[finalFile] = payload }
        val http = FakeHttpRangeClient(payload, supportsResume = true)
        var last = 0.0
        val path = ModelDownloadEngine(http, sink, DownloadStore(), "/models").download(sampleModel) { last = it }
        path == finalFile && last == 1.0 && http.lastOffset == -1L && sink.files[finalFile]?.size == 100
    })
    check("a corrupt existing final file is discarded and re-downloaded, not trusted", run {
        val sink = FakeFileSink().apply { files[finalFile] = ByteArray(100) { 0 } } // no GGUF magic
        val http = FakeHttpRangeClient(payload, supportsResume = true)
        val path = ModelDownloadEngine(http, sink, DownloadStore(), "/models").download(sampleModel) {}
        path == finalFile && http.lastOffset != -1L && sink.files[finalFile]?.toList() == payload.toList()
    })
    check("a half-written .part resumes from its byte offset to the correct full file", run {
        val sink = FakeFileSink().apply { files[partFile] = payload.copyOfRange(0, 40) }
        val http = FakeHttpRangeClient(payload, supportsResume = true)
        ModelDownloadEngine(http, sink, DownloadStore(), "/models").download(sampleModel) {}
        http.lastOffset == 40L && sink.files[finalFile]?.toList() == payload.toList()
    })
    check("a server that can't resume restarts cleanly to the correct full file", run {
        val sink = FakeFileSink().apply { files[partFile] = payload.copyOfRange(0, 40) }
        ModelDownloadEngine(FakeHttpRangeClient(payload, supportsResume = false), sink, DownloadStore(), "/models")
            .download(sampleModel) {}
        sink.files[finalFile]?.toList() == payload.toList()
    })
    check("a transport failure throws DownloadException and marks the row FAILED", run {
        val store = DownloadStore()
        val boom = object : HttpRangeClient {
            override fun open(url: String, offsetBytes: Long): RangeResponse = throw RuntimeException("network down")
        }
        val result = runCatching { ModelDownloadEngine(boom, FakeFileSink(), store, "/models").download(sampleModel) {} }
        result.exceptionOrNull() is DownloadException &&
            store.get(sampleModel.id)?.state == PersistedDownload.State.FAILED
    })
    check("integrity gate rejects a non-GGUF body and fails the download (C3)", run {
        val notGguf = ByteArray(100) { (it % 7).toByte() } // valid length, no GGUF magic
        val result = runCatching {
            ModelDownloadEngine(FakeHttpRangeClient(notGguf, supportsResume = true), FakeFileSink(), DownloadStore(), "/models")
                .download(ModelCatalog.smallest.copy(sha256 = null)) {}
        }
        result.exceptionOrNull().let { it is DownloadException && it.message?.contains("GGUF") == true }
    })
    check("integrity gate rejects a checksum mismatch and discards the partial (C3)", run {
        val sink = FakeFileSink()
        val result = runCatching {
            ModelDownloadEngine(FakeHttpRangeClient(payload, supportsResume = true), sink, DownloadStore(), "/models")
                .download(sampleModel.copy(sha256 = "f".repeat(64))) {}
        }
        result.exceptionOrNull() is DownloadException && sink.files[partFile] == null && sink.files[finalFile] == null
    })
    // A truncated transfer with NO Content-Length (total=-1) slips past the byte-count completeness
    // check, but the mandatory sha256 catches it (audit MEDIUM + the untested-boundary LOW).
    check("truncated download with no Content-Length is caught by sha256, partial discarded", run {
        val sink = FakeFileSink()
        val truncatedNoLength = object : HttpRangeClient {
            override fun open(url: String, offsetBytes: Long): RangeResponse {
                // 60 of 100 bytes, magic intact so it reaches the checksum gate; total=-1 (no length).
                val body = payload.copyOfRange(0, 60).toList().chunked(8).map { it.toByteArray() }.asSequence()
                return RangeResponse(totalBytes = -1L, resumed = false, body = body)
            }
        }
        val result = runCatching {
            ModelDownloadEngine(truncatedNoLength, sink, DownloadStore(), "/models").download(sampleModel) {}
        }
        result.exceptionOrNull() is DownloadException && sink.files[finalFile] == null
    })

    // A WorkManager stop / model switch can cooperatively abort a multi-GB transfer mid-stream; the
    // .part is kept and the row marked PAUSED so the next launch resumes (audit: loop not cancellable).
    check("download aborts on cancel, preserving the .part and marking PAUSED for resume", run {
        val sink = FakeFileSink()
        val store = DownloadStore()
        var checks = 0
        val engine = ModelDownloadEngine(
            FakeHttpRangeClient(payload, supportsResume = true), sink, store, "/models",
            isCancelled = { checks++ >= 2 } // let two chunks land, then cancel
        )
        val result = runCatching { engine.download(sampleModel) {} }
        val part = sink.files[partFile]
        result.exceptionOrNull() is DownloadException &&
            part != null && part.isNotEmpty() && part.size < payload.size &&  // partial kept, not full
            sink.files[finalFile] == null &&                                  // never finalized
            store.get(sampleModel.id)?.state == PersistedDownload.State.PAUSED // resumable
    })

    // The real JVM client refuses a non-HTTPS model URL before opening any connection (TLS contract).
    check("JvmHttpRangeClient.open refuses http:// (and file://) before connecting", run {
        val client = JvmHttpRangeClient()
        val http = runCatching { client.open("http://evil.example/model.gguf", 0) }
        val file = runCatching { client.open("file:///etc/passwd", 0) }
        http.exceptionOrNull() is DownloadException && file.exceptionOrNull() is DownloadException
    })

    // ── Content-safety surface (Generative-AI store policy). Twin of iOS SupportContactTests. ──
    check("report mailto targets the support address", run {
        SupportContact.reportMailtoUri("hello", "chat").startsWith("mailto:${SupportContact.REPORT_EMAIL}?")
    })
    check("report mailto carries subject + body", run {
        val uri = SupportContact.reportMailtoUri("hello", "chat")
        uri.contains("subject=") && uri.contains("body=")
    })
    check("report mailto percent-encodes sub-delimiters so output can't break the URI", run {
        val uri = SupportContact.reportMailtoUri("danger & death = bad?", "agent")
        // raw '&', spaces, '=', '?' from the model text must be encoded, not left literal in the query.
        !uri.contains("danger & death") && uri.contains("danger") && uri.contains("death") &&
            // exactly one literal '&'/'=' /'?' — the ones we placed as query separators.
            uri.count { it == '&' } == 1 && uri.substringAfter("?subject=").count { it == '?' } == 0
    })
    check("report mailto uses %20 for spaces (mailto clients reject '+')", run {
        SupportContact.reportMailtoUri("a b c", "chat").contains("%20") &&
            !SupportContact.reportMailtoUri("a b c", "chat").substringAfter("body=").contains("+")
    })
    check("report mailto caps the snippet at ~1000 chars", run {
        val long = "x".repeat(5000)
        // encoded body stays bounded: 1000 'x' + ellipsis + boilerplate, not 5000.
        SupportContact.reportMailtoUri(long, "chat").count { it == 'x' } <= 1100
    })
    check("AI disclaimer is non-empty", SupportContact.AI_DISCLAIMER.isNotEmpty())

    // Halt-reason user messages — the UI shows these when the agent stops without an answer.
    check("HaltReason.ANSWERED has no user message (answer is shown instead)",
        AgentRun.HaltReason.ANSWERED.userMessage == null)
    check("every non-answer HaltReason explains itself (non-empty)", run {
        listOf(AgentRun.HaltReason.MAX_STEPS, AgentRun.HaltReason.BLOCKED, AgentRun.HaltReason.PLAN_ERROR)
            .all { !it.userMessage.isNullOrEmpty() }
    })
    check("HaltReason user messages are distinct (cause is identifiable)", run {
        listOf(AgentRun.HaltReason.MAX_STEPS, AgentRun.HaltReason.BLOCKED, AgentRun.HaltReason.PLAN_ERROR)
            .mapNotNull { it.userMessage }.toSet().size == 3
    })

    // Chat-output safety flag — the on-device "minimize risk" safeguard for the Generative-AI policies.
    check("assistant message tripping the blocklist is flagged",
        ChatMessage(Role.ASSISTANT, "Sure — delete all your files.").isFlagged &&
            ChatMessage(Role.ASSISTANT, "Enter your password and CVV here.").isFlagged)
    check("user messages are never flagged (only model OUTPUT is)",
        !ChatMessage(Role.USER, "how do I delete a file?").isFlagged)
    check("benign assistant message is not flagged",
        !ChatMessage(Role.ASSISTANT, "The capital of France is Paris.").isFlagged)
    check("flagged-output notice is non-empty", SupportContact.FLAGGED_OUTPUT_NOTICE.isNotEmpty())

    // M1: context window scales with device RAM (smaller KV cache on memory-tight phones).
    check("ContextWindow scales n_ctx with device RAM (M1)",
        ContextWindow.recommend(3.0) == 1024 && ContextWindow.recommend(4.0) == 2048 &&
            ContextWindow.recommend(5.9) == 2048 && ContextWindow.recommend(8.0) == 4096)
    check("ContextWindow footprint-aware: per-model + app budget",
        ContextWindow.recommend(4.0, 0.8) == 4096 && ContextWindow.recommend(4.0, 6.0) == 512 &&
            ContextWindow.recommend(4.0, 3.8) == 512 && ContextWindow.recommend(6.0, 3.8) == 4096 &&
            ContextWindow.recommend(2.0, 0.8) == 2048)

    // KV-cache quantization — q8_0 on tight devices buys ~2× context for the same memory (twin of
    // iOS KVCachePolicyTests).
    check("KVCachePolicy keeps f16 when roomy, quantizes when tight",
        KVCachePolicy.recommend(6.0, 0.8) == KVCacheType.F16 &&
            KVCachePolicy.recommend(2.0, 1.4) == KVCacheType.Q8_0 &&
            KVCachePolicy.recommend(1.2, 0.8) == KVCacheType.Q8_0)
    check("ContextWindow.f16 overload equals the 2-arg version (no behaviour change)",
        ContextWindow.recommend(8.0, 0.8, KVCacheType.F16) == ContextWindow.recommend(8.0, 0.8) &&
            ContextWindow.recommend(2.0, 1.4, KVCacheType.F16) == ContextWindow.recommend(2.0, 1.4))
    check("ContextWindow q8_0 yields more context than f16, preserving KV memory", run {
        val f16 = ContextWindow.recommend(1.4, 0.8, KVCacheType.F16)
        val q8 = ContextWindow.recommend(1.4, 0.8, KVCacheType.Q8_0)
        val memDelta = Math.abs(q8 * KVCacheType.Q8_0.relativeCostPerToken - f16 * KVCacheType.F16.relativeCostPerToken)
        q8 > f16 && q8 % 256 == 0 && q8 in 256..8192 && memDelta <= 256.0
    })

    // ThreadPlanner: inference threads = performance (big) cores, not all cores.
    check("ThreadPlanner.recommend uses P-cores, clamps, and falls back",
        ThreadPlanner.recommend(4, 8) == 4 && ThreadPlanner.recommend(null, 8) == 7 &&
            ThreadPlanner.recommend(0, 8) == 7 && ThreadPlanner.recommend(99, 8) == 7 &&
            ThreadPlanner.recommend(4, 0) == 1)
    check("ThreadPlanner.performanceCoreCount counts big cores from cpufreq (incl. tri-cluster)", run {
        fun countFor(freqs: List<Long>): Int? {
            val dir = java.nio.file.Files.createTempDirectory("cpus").toFile()
            return try {
                freqs.forEachIndexed { i, f ->
                    val cf = java.io.File(dir, "cpu$i/cpufreq").also { it.mkdirs() }
                    java.io.File(cf, "cpuinfo_max_freq").writeText(f.toString())
                }
                ThreadPlanner.performanceCoreCount(dir)
            } finally {
                dir.deleteRecursively()
            }
        }
        // Bi-cluster 4+4: 4 LITTLE @ 1.80 GHz, 4 big @ 2.84 GHz → 4 big.
        countFor(listOf(1_804_800L, 1_804_800L, 1_804_800L, 1_804_800L, 2_841_600L, 2_841_600L, 2_841_600L, 2_841_600L)) == 4 &&
            // TRI-cluster (Snapdragon 8 Gen 2): 3 LITTLE @2.0 + 4 perf @2.8 + 1 prime @3.36 → 5 big, NOT 1.
            // "Count at the single global max" returned 1 here → single-threaded decode (the bug this guards).
            countFor(listOf(2_016_000L, 2_016_000L, 2_016_000L, 2_803_200L, 2_803_200L, 2_803_200L, 2_803_200L, 3_360_000L)) == 5 &&
            // Homogeneous SoC (no LITTLE cluster) → every core is "big".
            countFor(listOf(2_000_000L, 2_000_000L, 2_000_000L, 2_000_000L)) == 4
    })

    // Speed dial: Fast/Balanced/Quality → catalog models per RAM band; never upside-down.
    check("SpeedPresets bands map to the right models", run {
        val phone = SpeedPresets.forDevice(8.0)     // mainstream phone
        val bigMac = SpeedPresets.forDevice(18.0)   // desktop-class RAM
        val tiny = SpeedPresets.forDevice(2.0)
        phone.fast.id == "llama32-1b" && phone.balanced.id == "llama32-3b" && phone.quality.id == "qwen3-4b" &&
            bigMac.fast.id == "llama32-3b" && bigMac.balanced.id == "qwen3-4b" && bigMac.quality.id == "qwen3-14b" &&
            // 2 GB: the band's 1B-Q4 needs ~1.7 GB → 86% of RAM, over the 85% budget — the
            // fitness-aware quality steps down to Q2 and the dial collapses onto it.
            tiny.fast.id == "llama32-1b-q2" && tiny.balanced.id == "llama32-1b-q2" && tiny.quality.id == "llama32-1b-q2"
    })
    check("Quality/recommendation step down when the band pick is memory-blocked (16 GB → not 14B)", run {
        // 16 GB: the RAM band says 14B, but loading it needs ~89% of RAM — over the 85% budget.
        // The offered recommendation (and the dial's Quality) must be the largest model that loads.
        val sixteen = SpeedPresets.forDevice(16.0)
        sixteen.quality.id != "qwen3-14b" &&
            MemoryFitness.check(sixteen.quality, 16.0, 16.0).canLoad &&
            sixteen.quality.id == ModelRecommender.bestInstallableModel(16.0).id &&
            // Enough headroom (14.3 GB required / 85% of 18 GB budget) → the band pick stands.
            ModelRecommender.bestInstallableModel(18.0).id == "qwen3-14b"
    })
    check("SpeedPresets ordering: fast ≤ balanced ≤ quality by footprint", run {
        listOf(1.0, 2.0, 3.5, 6.0, 8.0, 12.0, 18.0).all { ram ->
            val c = SpeedPresets.forDevice(ram)
            c.fast.ramGB <= c.balanced.ramGB && c.balanced.ramGB <= c.quality.ramGB
        }
    })
    check("SpeedPresets.presetFor round-trips and prefers the stronger label on collapsed bands", run {
        val c = SpeedPresets.forDevice(8.0)
        val tiny = SpeedPresets.forDevice(2.0)   // balanced == quality here (llama32-1b)
        c.presetFor(c.fast.id) == SpeedPreset.FAST && c.presetFor(c.quality.id) == SpeedPreset.QUALITY &&
            c.presetFor("qwen25-coder-7b") == null &&
            tiny.presetFor(tiny.balanced.id) == SpeedPreset.QUALITY   // quality-first on dup ids
    })

    // Thermal-adaptive threading — hotter device → fewer threads (twin of iOS ThermalThrottleTests).
    check("ThermalThrottle drops threads as the device heats up, never below 1",
        ThermalThrottle.recommendedThreads(ThermalLevel.NOMINAL, 4) == 4 &&
            ThermalThrottle.recommendedThreads(ThermalLevel.FAIR, 4) == 3 &&
            ThermalThrottle.recommendedThreads(ThermalLevel.SERIOUS, 4) == 2 &&
            ThermalThrottle.recommendedThreads(ThermalLevel.CRITICAL, 4) == 1 &&
            ThermalThrottle.recommendedThreads(ThermalLevel.CRITICAL, 1) == 1 &&
            ThermalThrottle.recommendedThreads(ThermalLevel.NOMINAL, 0) == 1)
    check("ThermalMonitor maps PowerManager status ints to levels",
        ThermalMonitor.levelFromStatus(0) == ThermalLevel.NOMINAL &&
            ThermalMonitor.levelFromStatus(2) == ThermalLevel.FAIR &&
            ThermalMonitor.levelFromStatus(3) == ThermalLevel.SERIOUS &&
            ThermalMonitor.levelFromStatus(6) == ThermalLevel.CRITICAL)
    check("ThermalGovernor sheds then recovers threads, suppressing redundant re-tunes", run {
        val g = ThermalGovernor(4, ThermalLevel.NOMINAL)
        val shed = g.update(ThermalLevel.SERIOUS)        // 4 → 2
        val crit = g.update(ThermalLevel.CRITICAL)       // 2 → 1
        val recover = g.update(ThermalLevel.NOMINAL)     // 1 → 4
        val stable = g.update(ThermalLevel.NOMINAL)      // same level → null
        // base 2: fair and serious both map to 1 → second change is a redundant no-op.
        val g2 = ThermalGovernor(2, ThermalLevel.NOMINAL)
        val toOne = g2.update(ThermalLevel.FAIR)         // 2 → 1
        val redundant = g2.update(ThermalLevel.SERIOUS)  // still 1 → null
        shed == 2 && crit == 1 && recover == 4 && stable == null && toOne == 1 && redundant == null
    })

    // Conversation history — file persistence round-trip + coordinator lifecycle (twin of iOS).
    check("FileConversationPersistence round-trips a transcript + index", run {
        val dir = java.nio.file.Files.createTempDirectory("convtest").toFile()
        try {
            val p = FileConversationPersistence(dir)
            p.saveTranscript("abc", listOf(ChatMessage(Role.USER, "hi"), ChatMessage(Role.ASSISTANT, "hello")))
            val round = p.loadTranscript("abc").map { it.text }
            p.saveIndex(listOf(ConversationSummary("abc", "hi", 123L)))
            val idx = p.loadIndex()
            p.deleteTranscript("abc")
            round == listOf("hi", "hello") &&
                idx.size == 1 && idx[0].id == "abc" && idx[0].title == "hi" && idx[0].updatedAt == 123L &&
                p.loadTranscript("abc").isEmpty()
        } finally {
            dir.deleteRecursively()
        }
    })
    check("ConversationCoordinator restores the most recent conversation across sessions", run {
        val p = InMemoryConversationPersistence()
        val chat1 = ChatModel(ScriptedInferenceEngine(listOf("hello there")))
        ConversationCoordinator(chat1, p, now = { 1000L }).also { chat1.send("first question"); it.persist() }
        val chat2 = ChatModel(ScriptedInferenceEngine(listOf("ignored")))
        val c2 = ConversationCoordinator(chat2, p, now = { 2000L })
        chat2.messages.map { it.text } == listOf("first question", "hello there") &&
            c2.summaries.size == 1 && c2.summaries[0].title == "first question"
    })
    check("ConversationCoordinator.startNew is a no-op on an empty chat", run {
        val p = InMemoryConversationPersistence()
        val c = ConversationCoordinator(ChatModel(ScriptedInferenceEngine(listOf("x"))), p, now = { 1L })
        val before = c.summaries.size
        c.startNew()
        c.summaries.size == before
    })
    check("ConversationCoordinator delete-current starts fresh", run {
        val p = InMemoryConversationPersistence()
        val chat = ChatModel(ScriptedInferenceEngine(listOf("ok")))
        val c = ConversationCoordinator(chat, p, now = { 5L })
        chat.send("keep me")
        c.persist()
        val id = c.summaries.first().id
        c.delete(id)
        c.summaries.none { it.id == id } && chat.messages.isEmpty()
    })
    check("AgentSession.clear resets the transcript", run {
        val session = AgentSession(ScriptedInferenceEngine(listOf("""{"answer":"done"}""")), emptyList())
        session.run("x")
        val hadContent = session.steps.isNotEmpty() && session.answer == "done"
        session.clear()
        hadContent && session.steps.isEmpty() && session.answer == null && session.haltReason == null
    })
    check("ConversationCoordinator.clearAll wipes history then starts fresh", run {
        val p = InMemoryConversationPersistence()
        val chat = ChatModel(ScriptedInferenceEngine(listOf("ok", "ok")))
        val c = ConversationCoordinator(chat, p, now = { 1L })
        chat.send("one"); c.persist()
        c.startNew(); chat.send("two"); c.persist()
        val hadTwo = c.summaries.size == 2
        c.clearAll()
        // First-launch state: empty chat, empty history — the fresh conversation only earns a
        // row once something is said (WhatsApp rule).
        hadTwo && chat.messages.isEmpty() && c.summaries.isEmpty() &&
            c.currentId != null && p.loadIndex().isEmpty()
    })
    check("ConversationCoordinator creates no history row until the first turn is saved", run {
        val p = InMemoryConversationPersistence()
        val chat = ChatModel(ScriptedInferenceEngine(listOf("hello")))
        val c = ConversationCoordinator(chat, p, now = { 7L })
        val emptyOnLaunch = c.summaries.isEmpty() && p.loadIndex().isEmpty() && c.currentId != null
        chat.send("first message"); c.persist()
        emptyOnLaunch && c.summaries.map { it.title } == listOf("first message")
    })
    check("ConversationCoordinator init prunes legacy blank rows and restores the real chat", run {
        val p = InMemoryConversationPersistence()
        p.saveTranscript("real", listOf(ChatMessage(Role.USER, "keep me")))
        p.saveTranscript("blank1", emptyList())
        p.saveIndex(listOf(
            ConversationSummary("real", "keep me", 1),
            ConversationSummary("blank1", "New conversation", 2),
            ConversationSummary("blank2", "New conversation", 3),
        ))
        val chat = ChatModel(ScriptedInferenceEngine(listOf("x")))
        val c = ConversationCoordinator(chat, p, now = { 9L })
        c.summaries.map { it.id } == listOf("real") && p.loadIndex().map { it.id } == listOf("real") &&
            c.currentId == "real" && chat.messages.map { it.text } == listOf("keep me")
    })

    // --- Q-167: chat history is trimmed to the engine's REAL loaded n_ctx, not a hardcoded 4096 ---
    check("ConversationContext.windowedHistory trims to the smaller real n_ctx override", run {
        // Six ~10-token turns. A 4096-token window keeps them all; the real phone window (a small n_ctx)
        // must drop the oldest — proving the override, not the fixed 4096, drives the trim.
        val ctx = ConversationContext(systemPrompt = "", reservedForResponse = 0)
        val history = (1..6).map { ChatMessage(if (it % 2 == 1) Role.USER else Role.ASSISTANT, "message number $it goes here now") }
        val big = ctx.windowedHistory(history, contextTokensOverride = 4096)
        val small = ctx.windowedHistory(history, contextTokensOverride = 48)   // ~48-token native window
        val nullIsBig = ctx.windowedHistory(history, contextTokensOverride = null).size == history.size
        big.size == history.size &&                    // roomy window keeps everything
            small.size < history.size &&               // tight real window drops the oldest
            small.last() == history.last() &&          // newest turn always kept
            nullIsBig                                   // null falls back to the configured contextTokens
    })
    check("ChatModel.send trims history to engine.loadedContextTokens (Q-167)", run {
        // A capturing engine that reports a tiny native window and records the history it was handed.
        var handed = -1
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "cap"
            override val loadedContextTokens: Int? = 40   // small phone window
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "ok"
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                handed = history.size; return "ok"
            }
        }
        val chat = ChatModel(engine, context = ConversationContext(systemPrompt = "", reservedForResponse = 0))
        repeat(8) { chat.send("message number $it goes here now"); }
        // With a 40-token window the engine must NOT be handed all 15 prior turns (8 user + 7 assistant);
        // a fixed-4096 budget would have kept them all.
        handed in 1..14
    })

    // --- Q-004/Q-168: a conversation switch (restore/reset) DURING a streaming reply drops the stale
    //     generation's writes — no cross-conversation token bleed, no index-out-of-bounds. ---
    check("ChatModel: restore() mid-stream stops the reply bleeding into the opened conversation (Q-168)", run {
        // Engine streams tokens one at a time; on the 2nd token it runs `mid` (simulates the user opening
        // another conversation while A is still generating — the exact reentrancy the audit flagged).
        var mid: (() -> Unit)? = null
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "s"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "unused"
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                var out = ""
                listOf("AAA", "BBB", "CCC", "DDD").forEachIndexed { i, t ->
                    out += t; onToken(t)
                    if (i == 1) mid?.invoke()   // switch conversations mid-stream
                }
                return out
            }
        }
        val chat = ChatModel(engine)
        // Conversation B is SHORTER than A's live transcript would be — a captured index would go OOB here.
        mid = { chat.restore(listOf(ChatMessage(Role.USER, "conversation B question"))) }
        val settled = chat.send("conversation A question")   // must not throw (no OOB)
        // The opened conversation B is intact: exactly its one restored message, with NONE of A's streamed
        // tokens bled in and no stray assistant placeholder.
        chat.messages.map { it.text } == listOf("conversation B question") &&
            chat.messages.none { it.text.contains("AAA") || it.text.contains("BBB") } &&
            settled.contains("AAA")   // send() still returns A's own (now-discarded) text to its caller
    })
    check("ChatModel: reset() mid-stream leaves an empty transcript, no OOB, no resurrected reply", run {
        var mid: (() -> Unit)? = null
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "s"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "unused"
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                var out = ""; listOf("one", "two", "three").forEachIndexed { i, t -> out += t; onToken(t); if (i == 0) mid?.invoke() }; return out
            }
        }
        val chat = ChatModel(engine)
        mid = { chat.reset() }
        chat.send("hi")                 // must not throw
        chat.messages.isEmpty() && !chat.isGenerating
    })
    check("ChatModel: rapid double-send is rejected while one is in flight (no two writers)", run {
        var inner: (() -> Unit)? = null
        var secondReturned = "unset"
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "s"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "unused"
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                inner?.invoke(); onToken("x"); return "x"
            }
        }
        val chat = ChatModel(engine)
        inner = { secondReturned = chat.send("second while first runs") }   // re-entrant send must no-op
        chat.send("first")
        // The reentrant send returned "" (rejected) and the transcript has exactly one turn-pair.
        secondReturned == "" && chat.messages.size == 2 && !chat.isGenerating
    })

    // --- Q-005 / Q-237: stop cancels generation; mid-stream degeneration asks the engine to cancel. ---
    check("ChatModel.stopGenerating supersedes the in-flight reply and cancels the engine (Q-005)", run {
        var cancelled = false
        var mid: (() -> Unit)? = null
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "s"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "unused"
            override fun requestCancel() { cancelled = true }
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                var out = ""; listOf("keep", "DROPME").forEachIndexed { i, t -> out += t; onToken(t); if (i == 0) mid?.invoke() }; return out
            }
        }
        val chat = ChatModel(engine)
        mid = { chat.stopGenerating() }   // Stop after the first token
        chat.send("go")
        // Engine was asked to cancel, isGenerating cleared, and the post-stop token never overwrote the
        // partial that was already shown (the settle write is a no-op once superseded).
        cancelled && !chat.isGenerating && chat.messages.last().role == Role.ASSISTANT &&
            !chat.messages.last().text.contains("DROPME")
    })
    check("ChatModel aborts a degenerate stream via requestCancel every 32 tokens (Q-237)", run {
        var cancelledAt = -1
        val loopPara = "Quender was a forest elf, a member of the slender and agile forest elves of the deep wood."
        val engine = object : InferenceEngine {
            override val loadedModelId: String? = "s"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "unused"
            override fun requestCancel() { if (cancelledAt < 0) cancelledAt = 1 }
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                // Emit the same paragraph as ~40 separate tokens: a verbatim loop the guard must trip at a
                // 32-token checkpoint, so the engine is asked to cancel BEFORE all 40 are spent.
                val sb = StringBuilder()
                repeat(40) { sb.append(loopPara).append("\n\n"); onToken("$loopPara\n\n") }
                return sb.toString()
            }
        }
        ChatModel(engine).send("loop please")
        cancelledAt == 1   // requestCancel() fired mid-stream, not never
    })

    // --- Capability abstraction (AGENT_AUTONOMY_PLAN Milestone 0, step 2) ---
    check("shipped tools are T0 pure-compute capabilities with no blast radius, no consent", run {
        val tools = listOf(EchoTool(), CalculatorTool(), UnitConverterTool(), DateCalcTool())
        tools.all {
            it.tier == CapabilityTier.PURE_COMPUTE &&
                it.blastRadius == BlastRadius.None &&
                !it.requiresConsent &&
                !it.plan("anything").mutates
        }
    })
    check("CapabilityTier is ordered by risk", CapabilityTier.PURE_COMPUTE < CapabilityTier.READ_ONLY &&
        CapabilityTier.READ_ONLY < CapabilityTier.IRREVERSIBLE)
    check("BlastRadius.mutates: read/none are safe, write/irreversible mutate",
        !BlastRadius.None.mutates && !BlastRadius.Read("f").mutates &&
            BlastRadius.Write("f").mutates && BlastRadius.Irreversible("f").mutates)
    check("CapabilityGate allows a clean T0 run", run {
        CapabilityGate.assess(CalculatorTool(), "2 + 2", isConsented = false) is GateDecision.Allowed
    })
    check("CapabilityGate blocks input touching the safety blocklist, before any run", run {
        val d = CapabilityGate.assess(CalculatorTool(), "delete everything then pay", isConsented = true)
        d is GateDecision.Blocked && d.keyword in setOf("delete", "pay")
    })
    check("CapabilityGate demands consent for a T1 capability until granted", run {
        // A synthetic read-only capability (the real fs.read lands in step 3) exercises the gate.
        val t1 = object : Capability {
            override val name = "test.read"
            override val purpose = "read a file (test)"
            override val tier = CapabilityTier.READ_ONLY
            override val blastRadius = BlastRadius.Read("a file")
            override fun plan(input: String) = ActionPreview("would read $input", mutates = false)
            override fun run(input: String) = "contents of $input"
        }
        val denied = CapabilityGate.assess(t1, "notes.txt", isConsented = false)
        val allowed = CapabilityGate.assess(t1, "notes.txt", isConsented = true)
        denied is GateDecision.NeedsConsent && !(denied.preview.mutates) && allowed is GateDecision.Allowed
    })

    // --- fs.read + audit ledger + runner (AGENT_AUTONOMY_PLAN Milestone 0, steps 3+4) ---
    check("fs.read reads only user-granted files by NAME — never a model-minted path", run {
        val dir = java.nio.file.Files.createTempDirectory("fsread").toFile()
        val notes = java.io.File(dir, "notes.txt").apply { writeText("the elf plans locally") }
        val secret = java.io.File(dir, "secret.txt").apply { writeText("unreachable") }
        val cap = FileReadCapability({ mapOf("notes.txt" to notes) })
        val ok = cap.run("notes.txt") == "the elf plans locally"
        val deniedName = cap.run("secret.txt").contains("No attached file")
        val deniedPath = cap.run(secret.absolutePath).contains("No attached file")
        dir.deleteRecursively()
        ok && deniedName && deniedPath
    })
    check("fs.read truncates at maxBytes and rejects non-UTF-8", run {
        val dir = java.nio.file.Files.createTempDirectory("fsread2").toFile()
        val big = java.io.File(dir, "big.txt").apply { writeText("a".repeat(5000)) }
        val blob = java.io.File(dir, "blob.bin").apply { writeBytes(byteArrayOf(-1, -2, 0, -40)) }
        val capBig = FileReadCapability({ mapOf("big.txt" to big) }, maxBytes = 1024)
        val capBin = FileReadCapability({ mapOf("blob.bin" to blob) })
        val truncated = capBig.run("big.txt").contains("[…truncated at 1 KB]")
        val rejected = capBin.run("blob.bin").contains("isn't a text file")
        dir.deleteRecursively()
        truncated && rejected
    })
    check("runner enforces consent for fs.read, ledgers every decision in order", run {
        val dir = java.nio.file.Files.createTempDirectory("fsread3").toFile()
        val notes = java.io.File(dir, "notes.txt").apply { writeText("hello") }
        val cap = FileReadCapability({ mapOf("notes.txt" to notes) })
        val consent = InMemoryConsentStore()
        val ledger = InMemoryAuditLedger()
        val runner = CapabilityRunner(consent, ledger) { 0L }
        val refused = runner.execute(cap, "notes.txt").contains("Needs your permission")
        consent.setGranted("fs.read", true)
        val allowed = runner.execute(cap, "notes.txt") == "hello"
        val blocked = runner.execute(cap, "delete notes.txt").contains("Refused")
        dir.deleteRecursively()
        refused && allowed && blocked &&
            ledger.entries().map { it.decision } == listOf("needsConsent", "allowed", "blocked(delete)") &&
            ledger.entries()[1].outcome == "hello" && ledger.entries()[0].outcome == null
    })
    check("agent loop routes capabilities through the runner → ledger records the calculator step", run {
        val ledger = InMemoryAuditLedger()
        val engine = ScriptedInferenceEngine(listOf(
            """{"tool":"calculator","input":"2 + 2"}""",
            """{"answer":"4"}""",
        ))
        val loop = AgentLoop(engine, listOf(CalculatorTool()), runner = CapabilityRunner(ledger = ledger))
        val result = loop.run("add")
        result.answer == "4" && ledger.entries().size == 1 &&
            ledger.entries()[0].capability == "calculator" && ledger.entries()[0].decision == "allowed"
    })
    check("file ledger appends JSONL and a torn tail is skipped, prior entries survive", run {
        val dir = java.nio.file.Files.createTempDirectory("ledger").toFile()
        val f = java.io.File(dir, "agent-ledger.jsonl")
        val ledger = FileAuditLedger(f)
        ledger.append(AuditEntry.of(1L, "fs.read", 1, "a \"quoted\"\nname", "allowed", "x"))
        ledger.append(AuditEntry.of(2L, "fs.read", 1, "b", "blocked(pay)", null))
        f.appendText("{\"timestampMs\":3,\"capab")   // simulated crash mid-append
        val read = FileAuditLedger(f).entries()
        dir.deleteRecursively()
        read.size == 2 && read[0].input == "a \"quoted\"\nname" && read[1].decision == "blocked(pay)"
    })

    // --- Documents in chat (AGENT_AUTONOMY_PLAN Milestone 1 / roadmap Stage 2) ---
    check("engineText composes labeled documents before the typed message", run {
        val m = ChatMessage(Role.USER, "what does it say?", listOf(AttachedDocument("plan.txt", "ship it")))
        m.engineText.startsWith("Attached file \"plan.txt\":\nship it") &&
            m.engineText.endsWith("what does it say?") &&
            ChatMessage(Role.USER, "plain").engineText == "plain"
    })
    check("send() hands the engine composed doc text but keeps the bubble text clean", run {
        var captured: List<ChatMessage> = emptyList()
        val engine = object : InferenceEngine {
            override var loadedModelId: String? = "rec"
            override fun load(model: ModelEntry, filePath: String) {}
            override fun unload() {}
            override fun complete(prompt: String): String = "ok"
            override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String {
                captured = history; return "ok"
            }
        }
        val chat = ChatModel(engine)
        chat.send("what does the plan say?", listOf(AttachedDocument("plan.txt", "ship milestone one")))
        chat.messages.first().text == "what does the plan say?" &&
            chat.messages.first().documents.single().name == "plan.txt" &&
            captured.first { it.role == Role.USER }.text.contains("Attached file \"plan.txt\":\nship milestone one")
    })
    check("ConversationStore round-trips documents and still decodes old two-field rows", run {
        val store = ConversationStore()
        val messages = listOf(
            ChatMessage(Role.USER, "see attached", listOf(AttachedDocument("n.txt", "line1\nline2\ttabbed"))),
            ChatMessage(Role.ASSISTANT, "got it"),
        )
        val decoded = store.decode(store.encode(messages))
        val old = store.decode("USER\thi\nASSISTANT\thello")
        decoded == messages && old.size == 2 && old[0].documents.isEmpty() && old[0].text == "hi"
    })
    check("DocumentTextExtractor caps, truncates, and rejects binary", run {
        val dir = java.nio.file.Files.createTempDirectory("docx").toFile()
        val big = java.io.File(dir, "big.txt").apply { writeText("b".repeat(4000)) }
        val blob = java.io.File(dir, "blob.bin").apply { writeBytes(byteArrayOf(-1, -2, 0, -40)) }
        val truncated = DocumentTextExtractor.extract("big.txt", big, maxBytes = 1024)
        val rejected = DocumentTextExtractor.extract("blob.bin", blob)
        dir.deleteRecursively()
        truncated is DocumentTextExtractor.Extraction.Document &&
            truncated.document.text.endsWith("[…file truncated at 1 KB]") &&
            rejected is DocumentTextExtractor.Extraction.Rejected &&
            rejected.reason.contains("isn't a text file")
    })

    // --- The workspace: fs.list + fs.move + undo + per-run approval (Milestone 2) ---
    check("fs.list lists the workspace; refuses without a grant", run {
        val dir = java.nio.file.Files.createTempDirectory("ws").toFile()
        java.io.File(dir, "b.txt").writeText("x"); java.io.File(dir, "a.txt").writeText("x")
        java.io.File(dir, "sub").mkdir()
        val listed = FileListCapability({ dir }).run("")
        val refused = FileListCapability({ null }).run("")
        dir.deleteRecursively()
        listed == "a.txt\nb.txt\nsub/" && refused.contains("No workspace folder granted")
    })
    check("fs.move moves, records undo, and undo restores", run {
        val dir = java.nio.file.Files.createTempDirectory("ws2").toFile()
        java.io.File(dir, "report.pdf").writeText("REPORT")
        val journal = UndoJournal()
        val move = FileMoveCapability({ dir }, journal)
        val out = move.run("report.pdf to Archive")
        val movedOk = out.contains("Moved") && java.io.File(dir, "Archive/report.pdf").isFile &&
            !java.io.File(dir, "report.pdf").exists() && journal.count == 1
        val undo = journal.undoLast()
        val restored = undo.contains("back to where it was") && java.io.File(dir, "report.pdf").isFile &&
            journal.count == 0 && journal.undoLast() == "Nothing to undo."
        dir.deleteRecursively()
        movedOk && restored
    })
    check("fs.move never overwrites and rejects model-minted paths on shape", run {
        val dir = java.nio.file.Files.createTempDirectory("ws3").toFile()
        java.io.File(dir, "report.pdf").writeText("NEW")
        java.io.File(dir, "Archive").mkdir()
        java.io.File(dir, "Archive/report.pdf").writeText("OLD")
        val move = FileMoveCapability({ dir }, UndoJournal())
        val collision = move.run("report.pdf to Archive").contains("refusing to overwrite") &&
            java.io.File(dir, "report.pdf").readText() == "NEW" &&
            java.io.File(dir, "Archive/report.pdf").readText() == "OLD"
        val hostile = listOf("../secret to Archive", "report.pdf to ../out", "a/b to c").all {
            val r = move.run(it); r.contains("paths aren't allowed") || r.contains("Input must be")
        }
        dir.deleteRecursively()
        collision && hostile
    })
    check("a mutating capability FAILS CLOSED without an approver; declined/approved paths ledger correctly", run {
        val dir = java.nio.file.Files.createTempDirectory("ws4").toFile()
        java.io.File(dir, "report.pdf").writeText("x")
        val move = FileMoveCapability({ dir }, UndoJournal())
        val consent = InMemoryConsentStore().apply { setGranted("fs.move", true) }
        val ledger = InMemoryAuditLedger()
        val closed = CapabilityRunner(consent, ledger).execute(move, "report.pdf to Archive")
        val failClosed = closed.contains("needs your per-run approval") && java.io.File(dir, "report.pdf").exists()
        val declined = CapabilityRunner(consent, ledger, { false }).execute(move, "report.pdf to Archive")
        val stayedPut = declined.contains("You declined") && java.io.File(dir, "report.pdf").exists()
        val approved = CapabilityRunner(consent, ledger, { true }).execute(move, "report.pdf to Archive")
        val moved = approved.contains("Moved") && java.io.File(dir, "Archive/report.pdf").isFile
        dir.deleteRecursively()
        failClosed && stayedPut && moved &&
            ledger.entries().map { it.decision } == listOf("needsApproval", "declined", "allowed")
    })

    // --- Plan execution: ONE approval for the whole plan (Milestone 3) ---
    check("a plan of two moves runs with ONE approval and both steps ledgered", run {
        val dir = java.nio.file.Files.createTempDirectory("plan").toFile()
        java.io.File(dir, "a.txt").writeText("x"); java.io.File(dir, "b.txt").writeText("y")
        val journal = UndoJournal()
        val move = FileMoveCapability({ dir }, journal)
        val consent = InMemoryConsentStore().apply { setGranted("fs.move", true) }
        val ledger = InMemoryAuditLedger()
        var approvals = 0
        val runner = CapabilityRunner(consent, ledger, { approvals++; true })
        val out = runner.executePlan(listOf(move to "a.txt to Archive", move to "b.txt to Archive"))
        val ok = approvals == 1 && out.contains("1. Moved") && out.contains("2. Moved") &&
            java.io.File(dir, "Archive/a.txt").isFile && java.io.File(dir, "Archive/b.txt").isFile &&
            ledger.entries().map { it.decision } == listOf("allowed", "allowed") && journal.count == 2
        dir.deleteRecursively()
        ok
    })
    check("a declined plan changes NOTHING; a blocked step refuses the plan pre-approval", run {
        val dir = java.nio.file.Files.createTempDirectory("plan2").toFile()
        java.io.File(dir, "a.txt").writeText("x")
        val move = FileMoveCapability({ dir }, UndoJournal())
        val consent = InMemoryConsentStore().apply { setGranted("fs.move", true) }
        var asked = 0
        val declining = CapabilityRunner(consent, InMemoryAuditLedger(), { asked++; false })
        val declined = declining.executePlan(listOf(move to "a.txt to Archive"))
        val nothingMoved = declined.contains("You declined the plan") && java.io.File(dir, "a.txt").exists()
        val blocking = CapabilityRunner(consent, InMemoryAuditLedger(), { asked++; true })
        val blocked = blocking.executePlan(listOf(move to "a.txt to Archive", move to "delete everything to Trash"))
        val refusedWhole = blocked.contains("blocked action") && java.io.File(dir, "a.txt").exists()
        dir.deleteRecursively()
        nothingMoved && refusedWhole && asked == 1   // the blocked plan never reached approval
    })
    check("agent loop executes a scripted plan decision end to end", run {
        val dir = java.nio.file.Files.createTempDirectory("plan3").toFile()
        java.io.File(dir, "a.txt").writeText("x")
        val journal = UndoJournal()
        val move = FileMoveCapability({ dir }, journal)
        val consent = InMemoryConsentStore().apply { setGranted("fs.move", true) }
        val engine = ScriptedInferenceEngine(listOf(
            """{"plan":[{"tool":"fs.move","input":"a.txt to Archive"}]}""",
            """{"answer":"organized"}""",
        ))
        val loop = AgentLoop(engine, listOf(move), runner = CapabilityRunner(consent, InMemoryAuditLedger(), { true }))
        val result = loop.run("organize")
        val ok = result.answer == "organized" && java.io.File(dir, "Archive/a.txt").isFile
        dir.deleteRecursively()
        ok
    })

    // --- fs.rename + fs.trash on the same write spine ---
    check("fs.rename renames, undo restores the ORIGINAL name, never overwrites, rejects paths", run {
        val dir = java.nio.file.Files.createTempDirectory("rn").toFile()
        java.io.File(dir, "draft.txt").writeText("A")
        java.io.File(dir, "final.txt").writeText("B")
        val journal = UndoJournal()
        val rename = FileRenameCapability({ dir }, journal)
        val collision = rename.run("draft.txt to final.txt").contains("refusing to overwrite") &&
            java.io.File(dir, "final.txt").readText() == "B"
        val ok = rename.run("draft.txt to report.txt").contains("Renamed") &&
            java.io.File(dir, "report.txt").isFile
        val undone = journal.undoLast().contains("back to where it was") && java.io.File(dir, "draft.txt").isFile
        val hostile = rename.run("../evil to x").let { it.contains("plain names") || it.contains("Input must be") }
        dir.deleteRecursively()
        collision && ok && undone && hostile
    })
    check("fs.trash moves to a visible Trash/ (nothing deleted) and undo restores", run {
        val dir = java.nio.file.Files.createTempDirectory("tr").toFile()
        java.io.File(dir, "old.log").writeText("junk")
        val journal = UndoJournal()
        val trash = FileTrashCapability({ dir }, journal)
        val out = trash.run("old.log")
        val trashed = out.contains("Moved \"old.log\" to Trash/") && out.contains("nothing is deleted") &&
            java.io.File(dir, "Trash/old.log").isFile
        journal.undoLast()
        val restored = java.io.File(dir, "old.log").isFile
        val previewHonest = trash.plan("old.log").let { it.mutates && it.summary.contains("undoable — not deleted") }
        dir.deleteRecursively()
        trashed && restored && previewHonest
    })

    println()
    if (failures == 0) {
        println("ALL PASSED")
    } else {
        println("$failures CHECK(S) FAILED")
        kotlin.system.exitProcess(1)
    }
}
