package ai.quenderin.core

/**
 * Host checks for the Turnstone adaptations. No model weights and no device.
 * Comments marked adapt: are the parity ids shared with the Swift and TypeScript suites.
 */
fun verifyTurnstoneAdaptations() {
    // adapt:model-hold-recommend
    require(ModelSelectionHold.decide("  ", ModelAvailability.MISSING, ModelEvidence.ORDINARY) is ModelHoldDecision.Recommend)
    // adapt:model-hold-missing
    val missing = ModelSelectionHold.decide("qwen3-4b", ModelAvailability.MISSING, ModelEvidence.ORDINARY) as ModelHoldDecision.Wait
    require(missing.message == "\"qwen3-4b\" is not on this device. This choice stays selected and was not replaced. Choose another model to continue.")
    // adapt:model-hold-unreadable
    val unreadable = ModelSelectionHold.decide("gone", ModelAvailability.UNREADABLE, ModelEvidence.ORDINARY) as ModelHoldDecision.Wait
    require(unreadable.message.contains("cannot be read") && unreadable.message.contains("was not replaced"))
    // adapt:model-hold-incompatible
    val incompatible = ModelSelectionHold.decide("qwen3-4b", ModelAvailability.INCOMPATIBLE, ModelEvidence.ORDINARY) as ModelHoldDecision.Wait
    require(incompatible.message.contains("does not run in this build"))
    // adapt:model-hold-blocked
    val blocked = ModelSelectionHold.decide("bonsai2-27b", ModelAvailability.BLOCKED, ModelEvidence.EXPERIMENTAL_SOURCE) as ModelHoldDecision.Wait
    require(blocked.message.contains("does not fit the current memory gate"))
    require(blocked.message.contains(ModelSelectionHold.EXPERIMENTAL_SOURCE_NOTICE))
    // adapt:model-hold-experimental-notice
    val experimental = ModelSelectionHold.decide("bonsai2-27b", ModelAvailability.PRESENT, ModelEvidence.EXPERIMENTAL_SOURCE) as ModelHoldDecision.Use
    require(experimental.notice == ModelSelectionHold.EXPERIMENTAL_SOURCE_NOTICE)
    require((ModelSelectionHold.decide("qwen3-4b", ModelAvailability.PRESENT, ModelEvidence.ORDINARY) as ModelHoldDecision.Use).notice.isEmpty())

    val notes = GuidanceNotebook()
    // adapt:guidance-select-only
    require(notes.save("Packing", "Use {{model}} for {{other}}") is GuidanceResult.Ok)
    require(notes.render("Qwen3 4B") == null)
    require(notes.select("Missing") is GuidanceResult.Rejected)
    // adapt:guidance-one-active
    require(notes.save("Travel", "Short answers.") is GuidanceResult.Ok)
    require(notes.select("Packing") is GuidanceResult.Ok)
    require(notes.select("Travel") is GuidanceResult.Ok)
    require(notes.render("Qwen3 4B")!!.contains("Short answers."))
    require(!notes.render("Qwen3 4B")!!.contains("{{model}}"))
    // adapt:guidance-placeholder
    notes.select("Packing")
    val rendered = notes.render("Qwen3 4B")!!
    require(rendered.contains("Use Qwen3 4B for {{other}}"))
    // adapt:guidance-no-model-knob
    require(rendered.contains("does not change the model or which tools can run"))
    require(!rendered.contains("temperature"))
    require(notes.save("", "x") is GuidanceResult.Rejected)

    val writers = ConversationWriter()
    // adapt:writer-one-owner
    val first = writers.claim("chat-1", "writer-a", 1_000, 500) as WriterClaim.Granted
    val second = writers.claim("chat-1", "writer-b", 1_200, 500) as WriterClaim.Busy
    require(second.message == "This conversation already has a live reply from \"writer-a\". Wait for it to finish.")
    require(writers.release(first.permit, 1_200))
    // adapt:writer-expiry
    val expired = writers.claim("chat-1", "writer-a", 2_000, 100) as WriterClaim.Granted
    val recovered = writers.claim("chat-1", "writer-c", 2_100, 100) as WriterClaim.Granted
    require(recovered.permit.writerId == "writer-c")
    // adapt:writer-stale-release
    require(!writers.release(expired.permit, 2_100))
    require(!writers.release(recovered.permit.copy(token = "other"), 2_100))
    require(writers.release(recovered.permit, 2_100))

    val held = ConversationWriter()
    held.claim("same", "other-screen", System.currentTimeMillis(), 60_000)
    val blockedChat = ChatModel(MockInferenceEngine("ok"), writers = held)
    blockedChat.conversationKey = "same"
    require(blockedChat.send("hello") == "")
    require(blockedChat.messages.isEmpty())
    require(blockedChat.preparationError!!.contains("live reply"))

    var seenSystem: String? = null
    val recording = object : InferenceEngine by MockInferenceEngine("ok") {
        override fun completeChatOwned(systemPrompt: String, history: List<ChatMessage>, isCurrent: () -> Boolean, onToken: (String) -> Unit): String {
            seenSystem = systemPrompt
            onToken("ok")
            return "ok"
        }
    }
    val guided = ChatModel(recording)
    require(guided.guidance.save("Packing", "Use {{model}} for {{other}}") is GuidanceResult.Ok)
    require(guided.guidance.select("Packing") is GuidanceResult.Ok)
    val model = ModelCatalog.smallest
    require(guided.send("hello", model = model) == "ok")
    require(seenSystem!!.contains("Use ${model.label} for {{other}}"))
    require(seenSystem!!.contains("does not change the model or which tools can run"))

    val explicit = OnboardingModel(
        MockInferenceEngine(), MockModelDownloader(),
        recallActiveModelID = { ModelCatalog.smallest.id },
        activeModelFileExists = { false },
    )
    require(!explicit.restoreAtLaunch(explicitModel = true))
    val failed = explicit.phase as OnboardingPhase.Failed
    require(failed.reason.contains("is not on this device") && failed.reason.contains("was not replaced"))
    val unpinned = OnboardingModel(
        MockInferenceEngine(), MockModelDownloader(),
        recallActiveModelID = { ModelCatalog.smallest.id },
        activeModelFileExists = { false },
    )
    require(!unpinned.restoreAtLaunch() && unpinned.phase is OnboardingPhase.Idle)
}
