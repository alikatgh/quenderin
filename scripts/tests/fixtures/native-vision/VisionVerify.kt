package ai.quenderin.core

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

object VisionFixture { @JvmStatic external fun active(): Int; @JvmStatic external fun balance(): Int }

fun main(args: Array<String>) {
    check(NativeVisionEngine.available)
    val model = VisionModels.all[0]; val root = File(args.single())
    val main = File(root, model.artifacts[0].filename).absolutePath
    val projector = File(root, model.artifacts[1].filename).absolutePath
    val image = File(root, "🌲.png").absolutePath
    val engine = NativeVisionEngine("", { Long.MAX_VALUE })
    try { engine.answer(model, main, projector, image, "Unicode 🌲", 1); error("Low memory accepted") } catch (_: IllegalArgumentException) {}
    try { engine.answer(model.copy(minimumMemoryBytes = 1), main, projector, image, "Unicode 🌲", Long.MAX_VALUE); error("Changed descriptor accepted") } catch (_: IllegalArgumentException) {}
    check(engine.answer(model, main, projector, image, "Unicode 🌲", Long.MAX_VALUE) == "Tree 🌲 < safe")
    val entered = CountDownLatch(1); val failure = AtomicReference<Throwable?>()
    val worker = thread {
        entered.countDown()
        try { engine.answer(model, main, projector, image, "BLOCK", Long.MAX_VALUE); failure.set(AssertionError("Cancelled answer succeeded")) }
        catch (error: IllegalStateException) { /* Native callback reports cancellation. */ }
        catch (error: Throwable) { failure.set(error) }
    }
    entered.await()
    for (attempt in 0..3000) { if (VisionFixture.active() == 1) break; Thread.sleep(1) }
    check(VisionFixture.active() == 1)
    try { engine.answer(model, main, projector, image, "Unicode 🌲", Long.MAX_VALUE); error("Concurrent answer accepted") } catch (_: IllegalStateException) {}
    engine.cancel(); worker.join(3000); check(!worker.isAlive); failure.get()?.let { throw it }
    check(engine.answer(model, main, projector, image, "Unicode 🌲", Long.MAX_VALUE) == "Tree 🌲 < safe")
    engine.close(); check(VisionFixture.balance() == 0)
    println("PASS: Kotlin actual JNI/C ABI load/generate, UTF-8, identity, memory, serialization and cancellation")
}
