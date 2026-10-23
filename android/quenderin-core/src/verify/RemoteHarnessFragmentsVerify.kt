package ai.quenderin.core

import java.io.File

private fun fragmentHex(source: String): ByteArray {
    check(source.length % 2 == 0)
    return ByteArray(source.length / 2) { source.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
private fun fragmentBytes(value: RemoteHarnessJSON): ByteArray {
    val f = value.objectValue()
    f["hex"]?.let { return fragmentHex(it.stringValue()) }
    val header = f["headerHex"]?.let { fragmentHex(it.stringValue()) } ?: byteArrayOf()
    val p = f["payload"]?.objectValue() ?: f
    val count = p["count"]?.integerValue()?.toInt() ?: 0
    val byte = p["byte"]?.integerValue()?.toInt() ?: 0
    val pattern = p["patternHex"]?.let { fragmentHex(it.stringValue()).also { bytes -> check(bytes.isNotEmpty()) } }
    check(count in 0..4_194_305 && byte in 0..255)
    return header + ByteArray(count) { if (pattern == null) byte.toByte() else pattern[it % pattern.size] }
}
private fun fragmentError(code: String, block: () -> Unit) {
    val error = try { block(); null } catch (error: RemoteHarnessException) { error }
    val expected = "fragment-" + code.replace(Regex("[A-Z]")) { "-" + it.value.lowercase() }
    check(error?.code == expected)
}
private fun fragmentHeader(id: Int, index: Int): ByteArray {
    // Independent synthetic golden 49,153-byte message; only ID/index are varied.
    val frame = fragmentHex(if (index == 0) "445348460100000001000000020000c001" else "445348460100000001000100020000c001")
    frame[5] = (id ushr 24).toByte(); frame[6] = (id ushr 16).toByte()
    frame[7] = (id ushr 8).toByte(); frame[8] = id.toByte()
    return frame + ByteArray(if (index == 0) 49_152 else 1) { 97 }
}
private fun fragmentOwnershipAndPrivacy() {
    val codec = RemoteHarnessFragments(1)
    val message = ByteArray(49_153) { 97 }
    val encoded = codec.encode(message, 1)
    message.fill(0)
    check(encoded[0].data.last() == 97.toByte())
    val first = encoded[0].data
    val original = first.copyOf()
    first.fill(0)
    check(encoded[0].data.contentEquals(original))
    val mutableWire = original.copyOf()
    check(codec.decode(mutableWire, 1, 0) == null)
    mutableWire.fill(0)
    val complete = checkNotNull(codec.decode(encoded[1].data, 1, 0))
    check(complete.data.contentEquals(ByteArray(49_153) { 97 }))
    val exported = complete.data; exported.fill(0)
    check(complete.data.first() == 97.toByte())
    val rawInput = byteArrayOf(0xff.toByte(), 0, 0x80.toByte())
    val raw = checkNotNull(codec.decode(rawInput, 1, 0)); rawInput.fill(0)
    check(raw.data.contentEquals(byteArrayOf(0xff.toByte(), 0, 0x80.toByte())))
    check(complete.toString() == "RemoteHarnessFragmentBytes(redacted)")
    check(codec.toString() == "RemoteHarnessFragments(redacted)")
    fragmentError("header") { codec.decode(fragmentHex("44534846"), 1, 0) }
}

/** Shared synthetic fixtures only. Outputs IDs/counts, never frames, keys or payloads. */
fun main(args: Array<String>) {
    check(args.size == 1)
    val file = File(args[0]); check(file.length() <= RemoteHarnessBounds.FRAME_BYTES)
    val root = RemoteHarnessJSON.parse(file.readText(Charsets.UTF_8)).objectValue()
    check(root.rhRequired("schemaVersion").integerValue() == 1L)
    check(root.rhString("upstreamRevision") == RemoteHarnessCodec.UPSTREAM_REVISION)
    val seen = mutableSetOf<String>()
    for (fixture in (root.rhRequired("cases") as RemoteHarnessJSON.ArrayValue).values) {
        val c = fixture.objectValue(); val id = c.rhString("id"); check(seen.add(id))
        try {
            val initial = c["initialMessageID"]?.integerValue() ?: 1L
            val codec = RemoteHarnessFragments(1, initial)
            for (value in (c.rhRequired("steps") as RemoteHarnessJSON.ArrayValue).values) {
                val s = value.objectValue()
                val generation = s["generation"]?.integerValue() ?: 1L
                val now = s["now"]?.let { (it as RemoteHarnessJSON.NumberValue).token.toLong() } ?: 0L
                fun execute() {
                    when (s.rhString("action")) {
                        "encode" -> {
                            val result = codec.encode(fragmentBytes(s.rhRequired("message")), generation)
                            s["expectedFrames"]?.let { expected ->
                                val frames = (expected as RemoteHarnessJSON.ArrayValue).values
                                check(result.size == frames.size)
                                frames.indices.forEach { check(result[it].data.contentEquals(fragmentBytes(frames[it]))) }
                            }
                        }
                        "decode" -> {
                            val actual = codec.decode(fragmentBytes(s.rhRequired("frame")), generation, now)
                            val expected = s["result"]
                            if (expected == null) check(actual == null)
                            else check(checkNotNull(actual).data.contentEquals(fragmentBytes(expected)))
                        }
                        "roundTrip" -> {
                            val message = fragmentBytes(s.rhRequired("message"))
                            val frames = codec.encode(message, generation)
                            check(frames.size.toLong() == s.rhRequired("frameCount").integerValue())
                            check(frames.first().data.take(17).toByteArray().contentEquals(fragmentHex(s.rhString("firstHeaderHex"))))
                            check(frames.last().data.take(17).toByteArray().contentEquals(fragmentHex(s.rhString("lastHeaderHex"))))
                            frames.dropLast(1).forEach { check(codec.decode(it.data, generation, now) == null) }
                            check(checkNotNull(codec.decode(frames.last().data, generation, now)).data.contentEquals(message))
                            check(codec.assemblyCount == 0 && codec.declaredByteCount == 0)
                        }
                        "state" -> check(codec.assemblyCount.toLong() == s.rhRequired("assemblies").integerValue() &&
                            codec.declaredByteCount.toLong() == s.rhRequired("declared").integerValue() &&
                            codec.isRetired == s.rhRequired("retired").booleanValue())
                        "expire" -> codec.checkExpiry(generation, now)
                        "reset" -> codec.reset(generation)
                        "retire" -> codec.retire(generation)
                        "receivedIDLimit" -> {
                            val count = s.rhRequired("count").integerValue().toInt()
                            repeat(count) { ordinal ->
                                check(codec.decode(fragmentHeader(ordinal + 1, 0), generation, now) == null)
                                check(checkNotNull(codec.decode(fragmentHeader(ordinal + 1, 1), generation, now)).data.size == 49_153)
                            }
                            fragmentError("idLimit") { codec.decode(fragmentHeader(count + 1, 0), generation, now) }
                        }
                        "ownershipAndPrivacy" -> fragmentOwnershipAndPrivacy()
                        else -> error("Unsupported synthetic fixture action")
                    }
                }
                val error = s["error"]
                if (error == null) execute() else fragmentError(error.stringValue(), ::execute)
            }
        } catch (_: Throwable) {
            System.err.println("REMOTE_HARNESS_FRAGMENT_FIXTURE_FAIL $id")
            throw IllegalStateException("Remote Harness fragment fixture failed: $id")
        }
        println("REMOTE_HARNESS_FRAGMENT_FIXTURE_PASS $id")
    }
    println("Remote Harness fragment fixtures: ${seen.size} passed")
}
