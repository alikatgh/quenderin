package ai.quenderin.core

import java.io.File

private fun wireLong(value: RemoteHarnessJSON): Long = (value as RemoteHarnessJSON.NumberValue).token.toLong()
private fun wireHex(value: String): ByteArray {
    check(value.length % 2 == 0)
    return ByteArray(value.length / 2) { value.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
}
private fun wireBytes(spec: Map<String, RemoteHarnessJSON>): ByteArray {
    spec["hex"]?.let { return wireHex(it.stringValue()) }
    val count = wireLong(spec.rhRequired("count")).toInt(); check(count in 0..65_536)
    val byte = wireLong(spec.rhRequired("byte")).toInt(); check(byte in 0..255)
    return ByteArray(count) { byte.toByte() }
}
private fun wireInput(spec: Map<String, RemoteHarnessJSON>): ByteArray {
    val text = spec["text"]?.stringValue() ?: run {
        val count = spec["count"]?.let(::wireLong)?.toInt() ?: 0; check(count in 0..1_048_577)
        (spec["prefix"]?.stringValue() ?: "") + (spec["token"]?.stringValue() ?: "").repeat(count) + (spec["suffix"]?.stringValue() ?: "")
    }
    var bytes = text.toByteArray(Charsets.UTF_8)
    spec["padTo"]?.let {
        val total = wireLong(it).toInt(); check(total in bytes.size..1_048_577)
        bytes += ByteArray(total - bytes.size) { 32 }
    }
    return bytes + (spec["appendHex"]?.let { wireHex(it.stringValue()) } ?: byteArrayOf())
}
private fun wirePacket(spec: Map<String, RemoteHarnessJSON>): RemoteHarnessControlPacket {
    val bytes = wireBytes(spec)
    return when (spec.rhString("type")) {
        "secure.handshake" -> RemoteHarnessControlPacket.Handshake(RemoteHarnessSecureHandshake(spec.rhString("connectionId"),
            spec.rhString("targetDeviceId"), wireLong(spec.rhRequired("step")).toInt(), bytes))
        "relay" -> RemoteHarnessControlPacket.Relay(RemoteHarnessSecureRelay(spec.rhString("connectionId"),
            spec.rhString("targetDeviceId"), wireLong(spec.rhRequired("counter")), bytes))
        else -> error("Fixture type")
    }
}
private fun wireCompare(envelope: RemoteHarnessControlEnvelope, spec: Map<String, RemoteHarnessJSON>) {
    check(envelope.id == spec.rhString("id") && envelope.timestamp == wireLong(spec.rhRequired("timestamp")))
    val expected = wireBytes(spec)
    when (val packet = envelope.packet) {
        is RemoteHarnessControlPacket.Handshake -> {
            check(spec.rhString("type") == "secure.handshake")
            check(packet.value.connectionID == spec.rhString("connectionId") && packet.value.targetDeviceID == spec.rhString("targetDeviceId"))
            check(packet.value.step.toLong() == wireLong(spec.rhRequired("step")) && packet.value.bytes.contentEquals(expected))
        }
        is RemoteHarnessControlPacket.Relay -> {
            check(spec.rhString("type") == "relay")
            check(packet.value.connectionID == spec.rhString("connectionId") && packet.value.targetDeviceID == spec.rhString("targetDeviceId"))
            check(packet.value.counter == wireLong(spec.rhRequired("counter")) && packet.value.ciphertext.contentEquals(expected))
        }
    }
    // Independent fixture literals verify type and binary producer output, and
    // prove unknown payload keys were stripped by the typed decoder.
    val encoded = RemoteHarnessControlWire.encode(envelope.packet, envelope.id, envelope.timestamp)
    val fields = RemoteHarnessJSON.parse(encoded).objectValue()
    check(fields.keys == setOf("v", "id", "type", "timestamp", "payload"))
    check(fields.rhString("type") == spec.rhString("type"))
    val payload = fields.rhRequired("payload").objectValue()
    val handshake = spec.rhString("type") == "secure.handshake"
    check(payload.keys == if (handshake) setOf("connectionId", "targetDeviceId", "step", "data")
        else setOf("connectionId", "targetDeviceId", "counter", "ciphertext"))
    spec["base64"]?.let { check(payload.rhString(if (handshake) "data" else "ciphertext") == it.stringValue()) }
}
private fun wirePrivacy() {
    val mutable = byteArrayOf(0, 0xff.toByte(), 0x80.toByte())
    val packet = RemoteHarnessControlPacket.Relay(RemoteHarnessSecureRelay("private-connection", "private-target", 0, mutable))
    mutable.fill(1)
    val encoded = RemoteHarnessControlWire.encode(packet, "private-header", 1)
    val decoded = RemoteHarnessControlWire.decode(encoded)
    encoded.fill(0)
    val bytes = (decoded.packet as RemoteHarnessControlPacket.Relay).value.ciphertext
    check(bytes.contentEquals(byteArrayOf(0, 0xff.toByte(), 0x80.toByte()))); bytes.fill(2)
    check(decoded.packet.value.ciphertext.first() == 0.toByte())
    check(decoded.toString() == "RemoteHarnessControlEnvelope(redacted)")
    check(packet.toString() == "RemoteHarnessControlPacket(redacted)")
    check(RemoteHarnessControlWire.toString() == "RemoteHarnessControlWire(redacted)")
    check(RemoteHarnessControlWireLimits().toString() == "RemoteHarnessControlWireLimits(redacted)")
    // JVM callers can construct malformed UTF-16 even though valid UTF-8 cannot.
    for (id in listOf("\ud800", "\udc00")) {
        var rejected = false
        try { RemoteHarnessControlWire.encode(packet, id, 1) } catch (_: RemoteHarnessException) { rejected = true }
        check(rejected)
    }
}

/** Original shared synthetic fixtures; output contains fixture IDs only. */
fun main(args: Array<String>) {
    check(args.size == 1)
    val file = File(args[0]); check(file.length() <= 262_144)
    val root = RemoteHarnessJSON.parse(file.readBytes()).objectValue()
    check(root.rhRequired("schemaVersion").integerValue() == 1L)
    check(root.rhString("upstreamRevision") == RemoteHarnessCodec.UPSTREAM_REVISION)
    check(root.rhString("origin").startsWith("Original Quenderin"))
    val seen = mutableSetOf<String>()
    for (value in (root.rhRequired("cases") as RemoteHarnessJSON.ArrayValue).values) {
        val fixture = value.objectValue(); val id = fixture.rhString("id"); check(seen.add(id))
        try {
            for (step in (fixture.rhRequired("steps") as RemoteHarnessJSON.ArrayValue).values) {
                val s = step.objectValue(); val reject = s["reject"]?.booleanValue() ?: false
                fun execute() {
                    val config = s["config"]?.objectValue() ?: emptyMap()
                    val limits = RemoteHarnessControlWireLimits(config["handshake"]?.let(::wireLong), config["relay"]?.let(::wireLong))
                    when (s.rhString("action")) {
                        "decode" -> {
                            val envelope = RemoteHarnessControlWire.decode(wireInput(s.rhRequired("wire").objectValue()), limits)
                            if (!reject) wireCompare(envelope, s.rhRequired("expected").objectValue())
                        }
                        "roundTrip" -> {
                            val spec = s.rhRequired("packet").objectValue()
                            val bytes = RemoteHarnessControlWire.encode(wirePacket(spec), spec.rhString("id"), wireLong(spec.rhRequired("timestamp")), limits)
                            if (!reject) wireCompare(RemoteHarnessControlWire.decode(bytes, limits), spec)
                        }
                        "config" -> if (!reject) check(limits.handshake.toLong() == wireLong(s.rhRequired("expectedHandshake")) &&
                            limits.relay.toLong() == wireLong(s.rhRequired("expectedRelay")))
                        "privacy" -> wirePrivacy()
                        else -> error("Fixture action")
                    }
                }
                if (reject) {
                    var rejected = false
                    try { execute() } catch (_: RemoteHarnessException) { rejected = true }
                    check(rejected)
                } else execute()
            }
        } catch (_: Exception) { error("Control wire fixture failed: $id") }
        println("REMOTE_HARNESS_CONTROL_WIRE_FIXTURE_PASS $id")
    }
}
