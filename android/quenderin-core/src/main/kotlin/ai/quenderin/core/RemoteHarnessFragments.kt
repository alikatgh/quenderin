package ai.quenderin.core

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections

/** Explicit byte access is a private-data export. Ordinary descriptions contain no payload. */
class RemoteHarnessFragmentBytes internal constructor(bytes: ByteArray) {
    private val storage = bytes.copyOf()
    val data: ByteArray get() = storage.copyOf()
    override fun toString() = "RemoteHarnessFragmentBytes(redacted)"
}

/**
 * Source-only DSHF plaintext framing, before/after the maintained Noise facade.
 * Protocol facts: liguobao/ds-harness-remote@9a60e783ec1ceaff6116b0462a2863f07f602a55,
 * packages/protocol/src/index.ts SecureMessageCodec. No transport, authentication or encryption.
 *
 * One owner must serialize a connection's fragments, call checkExpiry from its idle timer,
 * and retire this codec on disconnect. Only reset with a NEW authenticated generation may
 * reuse message IDs. Every error in the active generation retires and clears the codec;
 * the owner must close the authenticated connection instead of skipping a rejected frame.
 * Generation mismatch leaves the replacement connection intact. The generation is supplied
 * by the authenticated owner, never read from peer bytes.
 */
class RemoteHarnessFragments internal constructor(authenticatedGeneration: Long, initialMessageID: Long) {
    constructor(authenticatedGeneration: Long) : this(authenticatedGeneration, 1)

    companion object {
        const val CHUNK_BYTES = 49_152
        const val HEADER_BYTES = 17
        const val MESSAGE_BYTES = 4_194_304
        const val ASSEMBLIES = 8
        const val DECLARED_BYTES = 8_388_608
        const val DEADLINE_MS = 120_000L
        const val MAX_MESSAGE_ID = 0xffff_ffffL
        const val RECEIVED_IDS = 4_096
        private val MAGIC = byteArrayOf(0x44, 0x53, 0x48, 0x46)
    }
    private class Assembly(val total: Int, val byteCount: Int, val startedAt: Long) {
        val bytes = ByteArray(byteCount)
        var nextIndex = 0
        var received = 0
    }
    private var generation = authenticatedGeneration
    private var nextMessageID = initialMessageID
    private val receivedIDs = hashSetOf<Long>()
    private var lastMonotonic: Long? = null
    private val pending = linkedMapOf<Long, Assembly>()
    private var reservedBytes = 0
    @Volatile var isRetired = false; private set
    val assemblyCount: Int @Synchronized get() = pending.size
    val declaredByteCount: Int @Synchronized get() = reservedBytes

    init {
        rhCheck(authenticatedGeneration > 0 && initialMessageID in 1..MAX_MESSAGE_ID, "fragment-initial-state")
    }
    @Synchronized override fun toString() = "RemoteHarnessFragments(redacted)"

    @Synchronized fun retire(authenticatedGeneration: Long) {
        rhCheck(authenticatedGeneration == generation, "fragment-generation")
        retireActiveGeneration()
    }
    private fun retireActiveGeneration() {
        pending.clear(); receivedIDs.clear(); reservedBytes = 0; isRetired = true
    }
    @Synchronized fun reset(newAuthenticatedGeneration: Long) {
        rhCheck(newAuthenticatedGeneration > generation, "fragment-generation")
        pending.clear(); reservedBytes = 0; generation = newAuthenticatedGeneration
        nextMessageID = 1; receivedIDs.clear(); lastMonotonic = null; isRetired = false
    }
    private fun requireGeneration(authenticatedGeneration: Long) {
        rhCheck(authenticatedGeneration == generation, "fragment-generation")
        rhCheck(!isRetired, "fragment-retired")
    }
    private fun fail(code: String): Nothing {
        retireActiveGeneration(); throw RemoteHarnessException(code)
    }
    private fun requireFrame(valid: Boolean, code: String) { if (!valid) fail(code) }
    private fun startsWithMagic(data: ByteArray) = data.size >= 4 && MAGIC.indices.all { data[it] == MAGIC[it] }

    @Synchronized fun encode(message: ByteArray, authenticatedGeneration: Long): List<RemoteHarnessFragmentBytes> {
        requireGeneration(authenticatedGeneration)
        requireFrame(nextMessageID <= MAX_MESSAGE_ID, "fragment-counter-exhausted")
        requireFrame(message.size <= MESSAGE_BYTES, "fragment-message-limit")
        if (message.size <= CHUNK_BYTES) {
            // Upstream reserves this prefix for headers; emitting it raw is ambiguous.
            requireFrame(!startsWithMagic(message), "fragment-reserved-prefix")
            return Collections.singletonList(RemoteHarnessFragmentBytes(message))
        }
        val id = nextMessageID++
        val total = (message.size + CHUNK_BYTES - 1) / CHUNK_BYTES
        val frames = ArrayList<RemoteHarnessFragmentBytes>(total)
        repeat(total) { index ->
            val start = index * CHUNK_BYTES
            val count = minOf(CHUNK_BYTES, message.size - start)
            val frame = ByteBuffer.allocate(HEADER_BYTES + count).order(ByteOrder.BIG_ENDIAN)
            frame.put(MAGIC).put(1).putInt(id.toInt()).putShort(index.toShort())
                .putShort(total.toShort()).putInt(message.size).put(message, start, count)
            frames.add(RemoteHarnessFragmentBytes(frame.array()))
        }
        return Collections.unmodifiableList(frames)
    }

    /** Absolute first-fragment deadline: traffic cannot extend a partial message's lifetime. */
    @Synchronized fun checkExpiry(authenticatedGeneration: Long, monotonicMilliseconds: Long) {
        requireGeneration(authenticatedGeneration)
        requireFrame(monotonicMilliseconds >= 0 && (lastMonotonic == null || monotonicMilliseconds >= lastMonotonic!!), "fragment-clock")
        lastMonotonic = monotonicMilliseconds
        requireFrame(pending.values.none { monotonicMilliseconds - it.startedAt >= DEADLINE_MS }, "fragment-expired")
    }

    /** Receives authenticated DECRYPTED plaintext only. A null result is incomplete, never text. */
    @Synchronized fun decode(frame: ByteArray, authenticatedGeneration: Long, monotonicMilliseconds: Long): RemoteHarnessFragmentBytes? {
        checkExpiry(authenticatedGeneration, monotonicMilliseconds)
        requireFrame(frame.size <= CHUNK_BYTES + HEADER_BYTES, "fragment-frame-limit")
        if (!startsWithMagic(frame)) {
            requireFrame(frame.size <= CHUNK_BYTES, "fragment-raw-limit")
            return RemoteHarnessFragmentBytes(frame)
        }
        requireFrame(frame.size >= HEADER_BYTES && frame[4] == 1.toByte(), "fragment-header")
        val header = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN)
        val id = header.getInt(5).toLong() and MAX_MESSAGE_ID
        val index = header.getShort(9).toInt() and 0xffff
        val total = header.getShort(11).toInt() and 0xffff
        val bytes = header.getInt(13).toLong() and MAX_MESSAGE_ID
        requireFrame(id != 0L && bytes > CHUNK_BYTES && bytes <= MESSAGE_BYTES && total >= 2 && index < total &&
            total.toLong() == (bytes + CHUNK_BYTES - 1) / CHUNK_BYTES, "fragment-metadata")
        val expected = minOf(CHUNK_BYTES.toLong(), bytes - index.toLong() * CHUNK_BYTES).toInt()
        requireFrame(frame.size - HEADER_BYTES == expected, "fragment-length")
        var assembly = pending[id]
        if (assembly == null) {
            requireFrame(index == 0 && id !in receivedIDs, "fragment-sequence")
            requireFrame(receivedIDs.size < RECEIVED_IDS, "fragment-id-limit")
            requireFrame(pending.size < ASSEMBLIES && bytes <= DECLARED_BYTES - reservedBytes, "fragment-assembly-limit")
            assembly = Assembly(total, bytes.toInt(), monotonicMilliseconds)
            pending[id] = assembly; reservedBytes += assembly.byteCount; receivedIDs.add(id)
        }
        requireFrame(assembly.total == total && assembly.byteCount.toLong() == bytes && assembly.nextIndex == index, "fragment-sequence")
        frame.copyInto(assembly.bytes, assembly.received, HEADER_BYTES)
        assembly.received += expected; assembly.nextIndex++
        if (assembly.nextIndex < total) return null
        requireFrame(assembly.received == assembly.byteCount, "fragment-length")
        pending.remove(id); reservedBytes -= assembly.byteCount
        return RemoteHarnessFragmentBytes(assembly.bytes)
    }
}
