package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class SpecialistInferenceLease internal constructor(private val restore: () -> Unit) {
    private var finished = false
    private var failure: Throwable? = null
    @Synchronized fun resume() {
        if (finished) { failure?.let { throw it }; return }
        try { restore() } catch (error: Throwable) { failure = error; throw error } finally { finished = true }
    }
}

/** Serializes ordinary calls and grants one exclusive, unloaded specialist interval. */
class CoordinatedInferenceEngine(private val underlying: InferenceEngine) : InferenceEngine {
    private val state = ReentrantLock()
    private val changed = state.newCondition()
    private val operations = ReentrantLock()
    private var held = false
    private var admitted = 0
    private var selected: Pair<ModelEntry, String>? = null
    override val isSuspendedForSpecialist: Boolean get() = state.withLock { held }
    override val loadedModelId: String? get() = state.withLock { if (held) null else underlying.loadedModelId }
    override val loadedContextTokens: Int? get() = state.withLock { if (held) null else underlying.loadedContextTokens }
    override fun requestCancel() = underlying.requestCancel()
    private fun <T> ordinary(work: () -> T): T {
        state.withLock { check(!held) { BUSY }; admitted++ }
        try {
            return operations.withLock { state.withLock { check(!held) { BUSY } }; work() }
        } finally { state.withLock { admitted--; changed.signalAll() } }
    }
    override fun load(model: ModelEntry, filePath: String) = ordinary {
        underlying.load(model, filePath); selected = model to filePath
    }
    override fun unload() {
        if (isSuspendedForSpecialist) return
        try { ordinary { underlying.unload(); selected = null } } catch (error: IllegalStateException) { if (!isSuspendedForSpecialist) throw error }
    }
    override fun complete(prompt: String): String = ordinary { underlying.complete(prompt) }
    override fun complete(prompt: String, onToken: (String) -> Unit): String = ordinary { underlying.complete(prompt, onToken) }
    override fun completeChat(systemPrompt: String, history: List<ChatMessage>, onToken: (String) -> Unit): String = ordinary { underlying.completeChat(systemPrompt, history, onToken) }
    override fun completeThinking(prompt: String, maxTokens: Int): String = ordinary { underlying.completeThinking(prompt, maxTokens) }
    override fun completeWithGrammar(prompt: String, grammar: String, maxTokens: Int, topP: Float, topK: Int, temperature: Float, repeatPenalty: Float, repeatLastN: Int): String =
        ordinary { underlying.completeWithGrammar(prompt, grammar, maxTokens, topP, topK, temperature, repeatPenalty, repeatLastN) }
    override fun lastHitTokenCap(): Boolean = if (isSuspendedForSpecialist) false else underlying.lastHitTokenCap()
    override fun setChatTokenBudget(tokens: Int) = underlying.setChatTokenBudget(tokens)
    override fun thinkingEnabled(): Boolean = underlying.thinkingEnabled()
    override fun setThinkingEnabled(enabled: Boolean) = underlying.setThinkingEnabled(enabled)
    override fun suspendForSpecialist(): SpecialistInferenceLease {
        state.withLock { check(!held) { BUSY }; held = true }
        var interrupted = false
        try {
            // A just-admitted completion can reset its native cancel flag. Repeat until it has
            // actually left the ordinary-call boundary, then join/unload under the same owner lock.
            while (true) {
                underlying.requestCancel()
                val idle = state.withLock {
                    if (admitted == 0) true else {
                        try { changed.awaitNanos(5_000_000) } catch (_: InterruptedException) { interrupted = true }
                        false
                    }
                }
                if (idle) break
            }
            val snapshot = operations.withLock {
                val prior = selected?.takeIf { underlying.loadedModelId == it.first.id }
                underlying.unload(); prior
            }
            return SpecialistInferenceLease {
                try {
                    operations.withLock {
                        if (snapshot != null) {
                            val (model, path) = snapshot
                            try {
                                val file = File(path)
                                check(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS))
                                val identity = Files.readAttributes(file.toPath(), "unix:dev,ino,size,lastModifiedTime,ctime", LinkOption.NOFOLLOW_LINKS)
                                model.downloadBytes?.let { check(file.length() == it) }
                                if (model.artifacts.isNotEmpty()) ModelArtifacts.requireComplete(model, path)
                                else {
                                    file.inputStream().use { check(ModelIntegrity.hasGGUFMagic(ByteArray(4) { _ -> it.read().toByte() })) }
                                    model.sha256?.let { check(ModelIntegrity.sha256Hex(file) == it) }
                                }
                                check(identity == Files.readAttributes(file.toPath(), "unix:dev,ino,size,lastModifiedTime,ctime", LinkOption.NOFOLLOW_LINKS))
                                underlying.load(model, path); selected = snapshot
                            } catch (error: Throwable) {
                                underlying.unload()
                                throw IllegalStateException(RESTORE_FAILED, error)
                            }
                        }
                    }
                } finally { state.withLock { held = false; changed.signalAll() } }
            }
        } catch (error: Throwable) {
            state.withLock { held = false; changed.signalAll() }; throw error
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }
    companion object {
        const val BUSY = "Text inference is paused for an active specialist workflow. Finish or cancel that workflow first."
        const val RESTORE_FAILED = "The specialist finished, but the selected text model could not be restored from its installed file. Select it again to retry; your conversation and draft are kept."
    }
}
