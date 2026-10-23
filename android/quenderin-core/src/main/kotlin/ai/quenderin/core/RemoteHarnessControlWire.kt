package ai.quenderin.core

import java.util.Base64

/** Secure control subset only; authentication, sockets and local generation are external. */
class RemoteHarnessControlWireLimits(handshake: Long? = null, relay: Long? = null) {
    val handshake: Int = bound(handshake, HANDSHAKE_BYTES)
    val relay: Int = bound(relay, RELAY_BYTES)
    override fun toString() = "RemoteHarnessControlWireLimits(redacted)"
    companion object {
        const val HANDSHAKE_BYTES = 65_536
        const val RELAY_BYTES = 1_048_576
        private fun bound(value: Long?, maximum: Int): Int {
            if (value == null) return maximum
            rhCheck(value in 1..RemoteHarnessBounds.SAFE_INTEGER, "wire-invalid-limits")
            return minOf(value, maximum.toLong()).toInt()
        }
    }
}

sealed class RemoteHarnessControlPacket {
    final override fun toString() = "RemoteHarnessControlPacket(redacted)"
    class Handshake(val value: RemoteHarnessSecureHandshake) : RemoteHarnessControlPacket()
    class Relay(val value: RemoteHarnessSecureRelay) : RemoteHarnessControlPacket()
}

class RemoteHarnessControlEnvelope internal constructor(val id: String, val timestamp: Long, val packet: RemoteHarnessControlPacket) {
    override fun toString() = "RemoteHarnessControlEnvelope(redacted)"
}

object RemoteHarnessControlWire {
    private const val BINARY_BYTES = 65_535
    private const val ENCODED_CHARACTERS = 87_380
    override fun toString() = "RemoteHarnessControlWire(redacted)"
    private fun identity(value: String) { RemoteHarnessSecureClientID(value) }
    private fun base64(bytes: ByteArray): String {
        rhCheck(bytes.isNotEmpty() && bytes.size <= BINARY_BYTES, "wire-limit")
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
    private fun binary(value: RemoteHarnessJSON): ByteArray {
        val text = value.stringValue()
        rhCheck(text.isNotEmpty() && text.length <= ENCODED_CHARACTERS && text.length % 4 != 1 &&
            text.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' }, "wire-invalid-base64")
        val bytes = try { Base64.getUrlDecoder().decode(text) } catch (_: IllegalArgumentException) { throw RemoteHarnessException("wire-invalid-base64") }
        rhCheck(bytes.size <= BINARY_BYTES && base64(bytes) == text, "wire-invalid-base64")
        return bytes
    }
    fun encode(packet: RemoteHarnessControlPacket, id: String, timestamp: Long,
        limits: RemoteHarnessControlWireLimits = RemoteHarnessControlWireLimits()): ByteArray {
        identity(id); rhCheck(timestamp in 1..RemoteHarnessBounds.SAFE_INTEGER, "wire-invalid-frame")
        val type: String; val payload: RemoteHarnessJSON; val maximum: Int
        when (packet) {
            is RemoteHarnessControlPacket.Handshake -> {
                val value = packet.value; identity(value.connectionID); identity(value.targetDeviceID)
                rhCheck(value.step == 1 || value.step == 2, "wire-invalid-frame")
                type = "secure.handshake"; maximum = limits.handshake
                payload = RemoteHarnessJSON.obj("connectionId" to RemoteHarnessJSON.str(value.connectionID),
                    "targetDeviceId" to RemoteHarnessJSON.str(value.targetDeviceID), "step" to RemoteHarnessJSON.num(value.step.toLong()),
                    "data" to RemoteHarnessJSON.str(base64(value.bytes)))
            }
            is RemoteHarnessControlPacket.Relay -> {
                val value = packet.value; identity(value.connectionID); identity(value.targetDeviceID)
                rhCheck(value.counter in 0..RemoteHarnessBounds.SAFE_INTEGER, "wire-invalid-frame")
                type = "relay"; maximum = limits.relay
                payload = RemoteHarnessJSON.obj("connectionId" to RemoteHarnessJSON.str(value.connectionID),
                    "targetDeviceId" to RemoteHarnessJSON.str(value.targetDeviceID), "counter" to RemoteHarnessJSON.num(value.counter),
                    "ciphertext" to RemoteHarnessJSON.str(base64(value.ciphertext)))
            }
        }
        val frame = RemoteHarnessJSON.write(RemoteHarnessJSON.obj("v" to RemoteHarnessJSON.num(1), "id" to RemoteHarnessJSON.str(id),
            "type" to RemoteHarnessJSON.str(type), "timestamp" to RemoteHarnessJSON.num(timestamp), "payload" to payload)).toByteArray(Charsets.UTF_8)
        rhCheck(frame.size <= maximum, "wire-limit")
        return frame
    }
    fun decode(bytes: ByteArray, limits: RemoteHarnessControlWireLimits = RemoteHarnessControlWireLimits()): RemoteHarnessControlEnvelope {
        rhCheck(bytes.size <= RemoteHarnessControlWireLimits.RELAY_BYTES, "wire-limit")
        val fields = RemoteHarnessJSON.parse(bytes).objectValue()
        rhCheck(fields.keys == setOf("v", "id", "type", "timestamp", "payload"), "wire-invalid-frame")
        rhCheck(fields.rhRequired("v").integerValue() == 1L, "wire-invalid-frame")
        val id = fields.rhRequired("id").stringValue(); identity(id)
        val timestamp = fields.rhRequired("timestamp").integerValue(true)
        val type = fields.rhRequired("type").stringValue()
        val maximum = when (type) {
            "secure.handshake" -> limits.handshake
            "relay" -> limits.relay
            else -> throw RemoteHarnessException("wire-unsupported-type")
        }
        rhCheck(bytes.size <= maximum, "wire-limit")
        // Upstream payload objects strip unknown fields; the common envelope is strict.
        val payload = fields.rhRequired("payload").objectValue()
        val connection = payload.rhRequired("connectionId").stringValue()
        val target = payload.rhRequired("targetDeviceId").stringValue()
        identity(connection); identity(target)
        val packet = if (type == "secure.handshake") {
            val step = payload.rhRequired("step").integerValue()
            rhCheck(step == 1L || step == 2L, "wire-invalid-frame")
            RemoteHarnessControlPacket.Handshake(RemoteHarnessSecureHandshake(connection, target, step.toInt(), binary(payload.rhRequired("data"))))
        } else {
            RemoteHarnessControlPacket.Relay(RemoteHarnessSecureRelay(connection, target, payload.rhRequired("counter").integerValue(),
                binary(payload.rhRequired("ciphertext"))))
        }
        return RemoteHarnessControlEnvelope(id, timestamp, packet)
    }
}
