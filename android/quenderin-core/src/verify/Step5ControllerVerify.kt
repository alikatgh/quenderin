package ai.quenderin.core

import ai.quenderin.app.Step5Controller
import java.io.ByteArrayInputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking

/** Host-only fixture: compile with the actual app controller and bundled coroutines. */
fun main() = runBlocking {
    var requests = 0
    val transport = object : Step5Transport {
        override fun open(url: java.net.URI, body: ByteArray?, timeoutMs: Int): Step5Response {
            val text = if (body == null) "{\"protocol\":1,\"modelRevision\":\"${Step5Contract.MODEL_REVISION}\",\"backendRevision\":\"${Step5Contract.BACKEND_REVISION}\",\"artifactsVerified\":true,\"ready\":true,\"maxOutputTokens\":1024,\"maxConcurrentRequests\":1}"
            else { requests++; "{\"text\":\"Synthetic fixture answer\",\"truncated\":false}" }
            return Step5Response(200, -1, ByteArrayInputStream(text.toByteArray())) {}
        }
        override fun cancel() {}
    }
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    try {
        val controller = Step5Controller(Step5Client({ transport }), scope)
        controller.endpoint("https://fixture.invalid"); controller.consent(true)
        for (exchange in 1..8) {
            controller.prompt("Synthetic exchange $exchange"); controller.send()
            repeat(200) { if (controller.state.value.busy) delay(5) }
            check(!controller.state.value.busy && controller.state.value.error == null)
            check(controller.state.value.messages.size == exchange * 2)
        }
        controller.prompt("Synthetic ninth exchange"); controller.send()
        check(!controller.state.value.busy && controller.state.value.error != null)
        check(controller.state.value.messages.size == 16 && controller.state.value.prompt == "Synthetic ninth exchange" && requests == 8)
        println("Step 5 native eighth-exchange boundary passed; ninth retained and rejected.")
    } finally { scope.cancel() }
}
