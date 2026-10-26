package ai.quenderin.core

import java.io.File

private fun Map<String, RemoteHarnessJSON>.attentionLong(key: String, fallback: Long? = null): Long =
    this[key]?.let { (it as RemoteHarnessJSON.NumberValue).token.toLong() } ?: checkNotNull(fallback)
private fun Map<String, RemoteHarnessJSON>.attentionBool(key: String, fallback: Boolean) = this[key]?.booleanValue() ?: fallback
private fun attentionScope(base: Map<String, RemoteHarnessJSON>, patch: Map<String, RemoteHarnessJSON>? = null): RemoteHarnessAttentionScope {
    val fields = base + (patch ?: emptyMap())
    return RemoteHarnessAttentionScope(fields.rhString("origin"), fields.rhString("clientDeviceID"), fields.rhString("hostID"),
        fields.rhString("hostFingerprint"), fields.rhString("workspaceID"), fields.rhString("sessionID"))
}
private fun attentionEvent(scope: RemoteHarnessAttentionScope, fields: Map<String, RemoteHarnessJSON>, defaultValidation: Boolean): RemoteHarnessAttentionEvent {
    val generation = fields.attentionLong("generation")
    val eventID = fields.rhString("eventID"); val kind = fields.rhString("kind")
    val issued = fields.attentionLong("issuedAt"); val expires = fields.attentionLong("expiresAt")
    val historical = fields.attentionBool("historical", false)
    return if (defaultValidation) RemoteHarnessAttentionEvent(scope, generation, eventID, kind, issued, expires, historical = historical)
    else RemoteHarnessAttentionEvent(scope, generation, eventID, kind, issued, expires,
        authenticatedAndNegotiated = fields.attentionBool("authenticatedAndNegotiated", false), historical = historical)
}

/** Paired synthetic local-policy fixtures. No network, OS delivery, credentials or work execution. */
fun main(args: Array<String>) {
    check(args.size == 1)
    val file = File(args[0]); check(file.length() <= RemoteHarnessBounds.FRAME_BYTES)
    val document = RemoteHarnessJSON.parse(file.readText(Charsets.UTF_8)).objectValue()
    check(document.rhRequired("schemaVersion").integerValue() == 1L)
    check(document.rhString("policyVersion") == "local-attention-v1")
    val baseScope = document.rhRequired("baseScope").objectValue()
    val baseEvent = document.rhRequired("baseEvent").objectValue()
    val seen = mutableSetOf<String>()
    for (fixtureValue in (document.rhRequired("cases") as RemoteHarnessJSON.ArrayValue).values) {
        val fixture = fixtureValue.objectValue(); val id = fixture.rhString("id"); check(seen.add(id))
        try {
            val policy = RemoteHarnessAttentionPolicy()
            val fixtureScopeFields = baseScope + (fixture["scope"]?.objectValue() ?: emptyMap())
            for (stepValue in (fixture.rhRequired("steps") as RemoteHarnessJSON.ArrayValue).values) {
                val step = stepValue.objectValue(); val action = step.rhString("action")
                check(action in setOf("evaluate", "evaluateDefaultEnabled", "evaluateDefaultValidation", "fill"))
                val current = attentionScope(fixtureScopeFields, step["currentScope"]?.objectValue())
                val eventPatch = step["event"]?.objectValue() ?: emptyMap()
                val scope = attentionScope(fixtureScopeFields, eventPatch["scope"]?.objectValue())
                val viewed = step["viewedScope"]?.let { attentionScope(fixtureScopeFields, it.objectValue()) }
                    ?: current.takeIf { step.attentionBool("viewing", false) }
                val count = if (action == "fill") step.attentionLong("count").toInt().also { check(it in 1..256) } else 1
                repeat(count) { index ->
                    val fields = baseEvent + eventPatch + if (action == "fill") mapOf("eventID" to RemoteHarnessJSON.str("fill-$index")) else emptyMap()
                    val event = attentionEvent(scope, fields, action == "evaluateDefaultValidation")
                    val generation = step.attentionLong("currentGeneration", 1)
                    val now = step.attentionLong("nowEpoch", 100_000)
                    val monotonic = step.attentionLong("nowMonotonic", 1_000)
                    val foreground = step.attentionBool("foreground", false)
                    val result = if (action == "evaluateDefaultEnabled") policy.evaluate(event, current, generation, now, monotonic,
                        foreground = foreground, viewedScope = viewed)
                    else policy.evaluate(event, current, generation, now, monotonic, enabled = step.attentionBool("enabled", true),
                        foreground = foreground, viewedScope = viewed)
                    check(result.disposition.wire == step.rhString("expect") && result.reason.wire == step.rhString("reason"))
                    check(!result.authorizesExecution)
                    if (result.disposition == RemoteHarnessAttentionDisposition.SUPPRESS) check(result.payload == null)
                    else {
                        val payload = checkNotNull(result.payload)
                        check(payload.title == "Remote Harness" && payload.body == "A remote session needs your attention.")
                        check(payload.eventID == event.eventID && payload.sessionID == event.scope.sessionID)
                        check(payload.toString() == "RemoteHarnessAttentionPayload(redacted)")
                    }
                    check(event.toString() == "RemoteHarnessAttentionEvent(redacted)")
                    check(result.toString() == "RemoteHarnessAttentionDecision(redacted)")
                }
                check(policy.rememberedCount.toLong() == step.attentionLong("remembered"))
            }
        } catch (error: Exception) {
            throw IllegalStateException("REMOTE_ATTENTION_CASE_FAIL $id", error)
        }
        println("REMOTE_ATTENTION_CASE_PASS $id")
    }
    check(seen.isNotEmpty())
}
