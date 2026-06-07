package ai.quenderin.core

/**
 * Deterministic engine that replays scripted replies in order — for testing the agent loop
 * (and multi-turn flows) without real inference. Mirrors iOS `ScriptedInferenceEngine`.
 */
class ScriptedInferenceEngine(private val replies: List<String>) : InferenceEngine {
    private var index = 0

    override var loadedModelId: String? = "scripted"
        private set

    override fun load(model: ModelEntry, filePath: String) {
        loadedModelId = model.id
    }

    override fun unload() {
        loadedModelId = null
    }

    override fun complete(prompt: String): String {
        val reply = replies.getOrNull(index) ?: """{"answer":"(no more scripted replies)"}"""
        index++
        return reply
    }
}
