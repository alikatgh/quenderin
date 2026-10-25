import ai.quenderin.core.MaxCloseResult
import ai.quenderin.core.MaxModelBinding
import ai.quenderin.core.MaxModelCode
import ai.quenderin.core.MaxModelFile
import ai.quenderin.core.MaxModelNative
import ai.quenderin.core.MaxModelReceipt
import ai.quenderin.core.MaxOpenResult
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

// Hosted JNI/JVM interoperability only. The library is built with the synthetic
// runner fixture; the app build has no runner and reports unavailable.
private fun digest(file: File): String =
    MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

private fun file(path: File) = MaxModelFile(path.absolutePath, path.length(), digest(path))

private fun fail(message: String): Nothing = error("MAX JNI fixture: $message")

/** Test-only native controls, implemented only by the synthetic-runner build. */
object MaxModelTestControl {
    @JvmStatic external fun waitTokenize(): Boolean
    @JvmStatic external fun releaseTokenize(): Boolean
}

fun main(args: Array<String>) {
    if (args.size != 1) fail("one new work directory is required")
    val directory = File(args[0]).apply { if (exists()) fail("work directory must be new"); mkdirs() }
    if (!MaxModelBinding.available) fail("the synthetic JNI library did not load")
    if (System.getenv("MODULAR_TELEMETRY_ENABLED") != "0" ||
        System.getenv("MODULAR_CRASH_REPORTING_ENABLED") != "0") {
        fail("telemetry opt-out environment is required")
    }

    val graph = File(directory, "graph.mef").apply { writeBytes("MEF synthetic graph\n".toByteArray()) }
    val tokenizer = File(directory, "tokenizer.bin").apply { writeBytes("tokenizer synthetic\n".toByteArray()) }
    val bulk = File(directory, "bulk.bin").apply { writeBytes(ByteArray(40000) { 'a'.code.toByte() }) }
    val receipt = MaxModelReceipt(
        files = listOf(file(graph), file(tokenizer), file(bulk)),
        runnerName = "fake-bonsai-runner", backend = "cpu", contextTokens = 64, maxOutputTokens = 16,
    )

    if (!MaxModelBinding.verify(receipt).succeeded) fail("verified receipt was rejected")
    val tampered = MaxModelReceipt(
        files = receipt.files.mapIndexed { index, value ->
            if (index == 0) value.copy(sha256 = "0".repeat(64)) else value
        },
        runnerName = receipt.runnerName, backend = receipt.backend,
        contextTokens = receipt.contextTokens, maxOutputTokens = receipt.maxOutputTokens,
    )
    if (MaxModelBinding.verify(tampered).succeeded) fail("tampered receipt was accepted")

    // Snapshot: mutating the caller-owned list after construction cannot change the receipt.
    val mutableFiles = receipt.files.toMutableList()
    val snapshot = MaxModelReceipt(mutableFiles, receipt.runnerName, receipt.backend,
        receipt.contextTokens, receipt.maxOutputTokens)
    mutableFiles[0] = mutableFiles[0].copy(sha256 = "")
    if (snapshot.files[0].sha256.length != 64) fail("receipt did not snapshot its file list")
    if (!MaxModelBinding.verify(snapshot).succeeded) fail("snapshot receipt changed after list mutation")

    // The JNI boundary must reject malformed hash lengths before copying 64 bytes.
    val paths = receipt.files.map { it.path }.toTypedArray()
    val sizes = receipt.files.map { it.bytes }.toLongArray()
    for (badHash in listOf("", "a", "a".repeat(63))) {
        val error = arrayOf("")
        val code = MaxModelNative.nativeVerify(
            paths, sizes,
            arrayOf(badHash, receipt.files[1].sha256, receipt.files[2].sha256),
            receipt.runnerName, receipt.backend, receipt.contextTokens, receipt.maxOutputTokens, error,
        )
        if (code == MaxModelCode.OK) fail("JNI accepted a ${badHash.length}-byte hash")
    }
    if (runCatching {
            MaxModelReceipt(listOf(MaxModelFile("relative.mef", 1, "0".repeat(64))),
                "runner", "cpu", 16, 4)
        }.isSuccess) fail("relative path was accepted")

    val opened = MaxModelBinding.open(receipt) as? MaxOpenResult.Opened ?: fail("open failed")
    val handle = opened.handle
    val capability = MaxModelBinding.capability(receipt, loadProbePassed = true)
    if (!capability.contractOk || !capability.available || capability.backend != "cpu") {
        fail("capability did not report the synthetic runner")
    }

    val text = StringBuilder()
    val generated = handle.generate("hi") { text.append(it); true }
    if (!generated.succeeded || generated.performance.status != 0) fail("generation failed")
    if (text.toString() != "hello \u00e9!") fail("decoded text differs: $text")
    if (generated.performance.promptTokens != 2 || generated.performance.decodedTokens != 6) {
        fail("performance counts differ")
    }

    // Supplementary scalar plus embedded NUL: the bridge must preserve both.
    val exotic = handle.generate("\uD83D\uDE42\u0000x", maxTokens = 4) { true }
    if (!exotic.succeeded) fail("supplementary/NUL prompt failed")

    // Cancellation from inside the token callback reaches the native lease.
    val cancelled = handle.generate("hi") { handle.cancel(); true }
    if (cancelled.code != MaxModelCode.CANCELLED || cancelled.performance.status != 1) {
        fail("cancellation from the sink did not stop generation")
    }

    // Cancellation after admission but before the first token (during tokenize).
    var beforeInit: ai.quenderin.core.MaxGenerationResult? = null
    val initThread = thread { beforeInit = handle.generate("__block__ hi") { true } }
    MaxModelTestControl.waitTokenize()
    if (!handle.cancel()) fail("cancel before initialization was not accepted")
    MaxModelTestControl.releaseTokenize()
    initThread.join(5000)
    if (initThread.isAlive) fail("pre-initialization cancel did not finish")
    if (beforeInit?.let { it.code == MaxModelCode.CANCELLED && it.performance.status == 1 } != true) {
        fail("pre-initialization cancellation did not stop generation")
    }

    // A token may be cancelled before native admission; the pending request must
    // cancel exactly that run and leave the handle reusable.
    val preAdmitted = handle.newRunToken()
    if (!handle.cancel(preAdmitted)) fail("pre-admission cancel was not accepted")
    val preResult = handle.generate("hi", token = preAdmitted) { true }
    if (preResult.code != MaxModelCode.CANCELLED || preResult.performance.status != 1) {
        fail("pre-admission cancellation did not stop the run")
    }
    if (!handle.generate("hi") { true }.succeeded) fail("handle was not reusable after pre-admission cancel")

    // A delayed token from an earlier run must not cancel the active run.
    val stale = handle.newRunToken()
    val blocked = CountDownLatch(1)
    val unblock = CountDownLatch(1)
    val first = java.util.concurrent.atomic.AtomicBoolean(true)
    var activeResult: ai.quenderin.core.MaxGenerationResult? = null
    val active = thread {
        activeResult = handle.generate("hi", token = handle.newRunToken()) {
            if (first.compareAndSet(true, false)) {
                blocked.countDown()
                unblock.await(5, TimeUnit.SECONDS)
            }
            true
        }
    }
    if (!blocked.await(5, TimeUnit.SECONDS)) fail("active run never reached the sink")
    if (handle.cancel(stale)) fail("stale token cancelled an active run")
    unblock.countDown()
    active.join(5000)
    if (active.isAlive || activeResult?.succeeded != true) fail("active run was affected by a stale cancel")

    // A second run is BUSY while the first is inside the sink; close refuses.
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    var workerResult: ai.quenderin.core.MaxGenerationResult? = null
    val worker = thread {
        workerResult = handle.generate("hi") {
            entered.countDown()
            release.await(5, TimeUnit.SECONDS)
            true
        }
    }
    if (!entered.await(5, TimeUnit.SECONDS)) fail("worker never entered the sink")
    if (handle.generate("hi") { true }.code != MaxModelCode.BUSY) fail("second run was not BUSY")
    if (handle.close() != MaxCloseResult.BUSY) fail("close did not refuse an active run")
    release.countDown()
    worker.join(5000)
    if (worker.isAlive || workerResult?.succeeded != true) fail("worker did not finish")

    // The same handle is reusable after cancellation and a refused close.
    if (!handle.generate("hi") { true }.succeeded) fail("handle was not reusable")
    if (handle.close() != MaxCloseResult.CLOSED) fail("close failed after generation")
    if (handle.close() != MaxCloseResult.CLOSED) fail("close was not idempotent")
    if (runCatching { handle.generate("hi") { true } }.isSuccess) fail("closed handle generated")

    val second = (MaxModelBinding.open(receipt) as? MaxOpenResult.Opened)?.handle ?: fail("second open failed")
    if (second.cancel()) fail("idle cancel reported a run")
    if (second.close() != MaxCloseResult.CLOSED) fail("second close failed")

    println("MAX JNI/JVM synthetic interop: receipt, capability, text, supplementary/NUL, cancellation, BUSY, close, reuse passed; no vendor runtime used")
}
