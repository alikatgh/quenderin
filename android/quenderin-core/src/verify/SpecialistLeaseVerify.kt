package ai.quenderin.core

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

private class LeaseFixtureEngine : InferenceEngine {
    override var loadedModelId: String? = null
    var loads = 0; var unloads = 0
    val entered = CountDownLatch(1)
    val stopped = AtomicBoolean(false)
    var loadGate: CountDownLatch? = null
    var loadEntered: CountDownLatch? = null
    override fun load(model: ModelEntry, filePath: String) {
        loadEntered?.countDown(); check(loadGate?.await(3, TimeUnit.SECONDS) != false)
        loads++; loadedModelId = model.id
    }
    override fun unload() { unloadedAfterJoin = !running.get(); check(unloadedAfterJoin); unloads++; loadedModelId = null }
    val running = AtomicBoolean(false)
    var unloadedAfterJoin = false
    override fun requestCancel() { stopped.set(true) }
    override fun complete(prompt: String): String {
        // Deliberately reset after admission, reproducing cancellation's start/reset race.
        stopped.set(false); running.set(true); entered.countDown()
        val deadline = System.nanoTime() + 3_000_000_000L
        while (!stopped.get() && System.nanoTime() < deadline) Thread.sleep(1)
        running.set(false); check(stopped.get()); return "partial answer"
    }
}
fun main(args: Array<String>) {
    val root = File(args.single()); val file = File(root, "selected.gguf"); file.writeText("GGUFsynthetic")
    val model = ModelCatalog.models.first().copy(id = "lease-fixture", filename = file.name, sha256 = ModelIntegrity.sha256Hex(file), downloadBytes = file.length(), artifacts = emptyList())
    val native = LeaseFixtureEngine(); val engine = CoordinatedInferenceEngine(native)
    engine.load(model, file.path)
    val output = AtomicReference<String>(); val worker = thread { output.set(engine.complete("question")) }
    check(native.entered.await(2, TimeUnit.SECONDS))
    val lease = engine.suspendForSpecialist()
    worker.join(1000); check(!worker.isAlive && output.get() == "partial answer")
    check(native.unloadedAfterJoin && native.loadedModelId == null && engine.isSuspendedForSpecialist)
    val loads = native.loads
    for (work in listOf<() -> Unit>({ engine.load(model, file.path) }, { engine.complete("blocked") }, { engine.suspendForSpecialist() })) {
        try { work(); error("Ordinary work entered exclusive lease") } catch (_: IllegalStateException) {}
    }
    check(native.loads == loads)
    lease.resume(); lease.resume(); check(!engine.isSuspendedForSpecialist && engine.loadedModelId == model.id && native.loads == loads + 1)
    val removed = engine.suspendForSpecialist(); check(file.delete())
    try { removed.resume(); error("Missing restore artifact accepted") } catch (error: IllegalStateException) { check(error.message == CoordinatedInferenceEngine.RESTORE_FAILED) }
    check(!engine.isSuspendedForSpecialist && native.loadedModelId == null)
    file.writeText("GGUFsynthetic"); engine.load(model, file.path) // recover without any downloader
    val emptyNative = LeaseFixtureEngine(); val empty = CoordinatedInferenceEngine(emptyNative)
    empty.suspendForSpecialist().resume(); check(emptyNative.loads == 0)
    val gatedNative = LeaseFixtureEngine().apply { loadGate = CountDownLatch(1); loadEntered = CountDownLatch(1) }
    val gated = CoordinatedInferenceEngine(gatedNative)
    val loader = thread { gated.load(model, file.path) }; check(gatedNative.loadEntered!!.await(2, TimeUnit.SECONDS))
    val acquired = CountDownLatch(1); val pendingLease = AtomicReference<SpecialistInferenceLease>()
    val suspender = thread { pendingLease.set(gated.suspendForSpecialist()); acquired.countDown() }
    check(!acquired.await(50, TimeUnit.MILLISECONDS)); gatedNative.loadGate!!.countDown()
    loader.join(1000); check(acquired.await(2, TimeUnit.SECONDS)); suspender.join(1000)
    check(gatedNative.loadedModelId == null); pendingLease.get().resume(); check(gated.loadedModelId == model.id)
    println("PASS: actual Kotlin exclusive lease cancels/joins, blocks load/generate, waits admitted load, restores locally and recovers")
}
