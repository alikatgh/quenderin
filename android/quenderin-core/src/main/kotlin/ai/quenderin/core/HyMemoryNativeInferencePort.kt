package ai.quenderin.core

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** A short-lived CPU specialist context; ordinary answer selection and history remain separate. */
class HyMemoryNativeInferencePort(nativeLibDir: String, private val availableMemoryBytes: () -> Long) : HyMemoryInferencePort {
    private val engine = LlamaEngine(deviceBudgetGb = 32.0, threads = 8, maxTokens = 512, temperature = 0.0, topP = 1.0).apply {
        this.nativeLibDir = nativeLibDir
    }
    private val busy = AtomicBoolean(false)
    private val cancelEpoch = AtomicLong(0)
    override val unavailableReason: String? get() = if (engine.available() && LlamaEngine.supportsBonsaiRuntime) null
        else "The verified native Prism specialist runtime is unavailable."
    override fun cancel() { cancelEpoch.incrementAndGet(); engine.requestCancel() }
    override fun generate(request: HyMemoryInferenceRequest, onToken: (String) -> Unit): String {
        val epoch = cancelEpoch.get()
        check(busy.compareAndSet(false, true)) { "A specialist generation is already running." }
        try {
            unavailableReason?.let { error(it) }
            var bytes = 0
            val output = StringBuilder()
            val stop = HyMemoryStopFilter { output.append(it); onToken(it) }
            engine.completeHyMemory(request, availableMemoryBytes, { cancelEpoch.get() != epoch }) { piece ->
                bytes += piece.toByteArray(Charsets.UTF_8).size
                check(bytes <= 65_536) { "Specialist output exceeded its bound." }
                stop.accept(piece)
            }
            stop.finish()
            return output.toString()
        } finally { engine.unload(); busy.set(false) }
    }
}

/** Holds only a possible EOS prefix, including across arbitrary JNI pieces. */
internal class HyMemoryStopFilter(private val emit: (String) -> Unit) {
    private val marker = "<eos:6124c78e>"
    private var pending = ""
    private var stopped = false
    fun accept(piece: String) {
        if (stopped) return
        pending += piece
        val end = pending.indexOf(marker)
        if (end >= 0) { if (end > 0) emit(pending.substring(0, end)); pending = ""; stopped = true; return }
        var held = 0
        for (n in 1 until marker.length) if (pending.endsWith(marker.substring(0, n))) held = n
        val ready = pending.substring(0, pending.length - held)
        pending = pending.substring(ready.length)
        if (ready.isNotEmpty()) emit(ready)
    }
    fun finish() { pending = "" }
}
