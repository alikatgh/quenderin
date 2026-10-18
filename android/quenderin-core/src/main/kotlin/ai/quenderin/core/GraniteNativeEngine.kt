package ai.quenderin.core

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class NativeGraniteEngine(nativeLibDir: String, private val availableMemoryBytes: () -> Long) {
    private val engine = LlamaEngine(deviceBudgetGb = 32.0, threads = 8, maxTokens = 512, temperature = 0.7, topP = 0.95).apply { this.nativeLibDir = nativeLibDir }
    private val busy = AtomicBoolean(false)
    private val epoch = AtomicLong(0)
    fun cancel() { epoch.incrementAndGet(); engine.requestCancel() }
    fun answer(proof: GraniteArtifactProof, messages: List<GraniteMessage>, cancelled: () -> Boolean = { false }): String {
        val start = epoch.get(); check(busy.compareAndSet(false, true)) { "Granite is already running." }
        try { check(available); return engine.completeGranite(proof, messages, availableMemoryBytes) { epoch.get() != start || cancelled() } }
        finally { engine.unload(); busy.set(false) }
    }
    companion object { val available: Boolean get() = LlamaEngine.NATIVE_AVAILABLE && LlamaEngine.supportsBonsaiRuntime && LlamaEngine.supportsWeeklyTextRuntime }
}
