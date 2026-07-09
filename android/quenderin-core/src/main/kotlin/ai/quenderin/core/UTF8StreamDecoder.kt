package ai.quenderin.core

/**
 * Decodes a token stream's bytes into text WITHOUT corrupting characters that BPE split across
 * tokens. Every Cyrillic letter is 2 bytes and emoji are 4 — tokenizers cut through them freely,
 * and decoding each token's bytes independently turns the cut halves into U+FFFD "�" garbage
 * mid-stream. This holds incomplete trailing sequences (at most 3 bytes) until their
 * continuation arrives.
 *
 * Twin of Swift `UTF8StreamDecoder` and the C++ class in `jni/llama_generate.h`. The JNI path
 * applies the C++ twin at emit time; this pure-Kotlin copy is the unit-testable twin and a
 * belt-and-suspenders for any pure-JVM streaming source.
 */
class UTF8StreamDecoder {
    private val pending = ArrayList<Byte>(4)

    /** Feed one token's bytes; returns whatever text is COMPLETE so far. */
    fun feed(bytes: ByteArray): String {
        for (b in bytes) pending.add(b)
        val keep = incompleteTailLength(pending)
        val readyLen = pending.size - keep
        if (readyLen <= 0) return ""
        val ready = ByteArray(readyLen) { pending[it] }
        // Drop the ready prefix, keep the incomplete tail.
        if (keep == 0) pending.clear()
        else {
            val tail = pending.subList(readyLen, pending.size).toList()
            pending.clear()
            pending.addAll(tail)
        }
        return String(ready, Charsets.UTF_8)
    }

    /** End of stream: decode whatever is left (lossy for genuinely truncated sequences). */
    fun flush(): String {
        if (pending.isEmpty()) return ""
        val left = ByteArray(pending.size) { pending[it] }
        pending.clear()
        return String(left, Charsets.UTF_8)
    }

    companion object {
        /**
         * How many bytes at the END of [bytes] are the start of a NOT-YET-COMPLETE UTF-8 character
         * (0 when the buffer ends on a character boundary). Looks back at most 3 bytes.
         */
        fun incompleteTailLength(bytes: List<Byte>): Int {
            var back = 0
            while (back < 3 && back < bytes.size) {
                val byte = bytes[bytes.size - 1 - back].toInt() and 0xFF
                if (byte and 0b1100_0000 == 0b1000_0000) { // continuation
                    back += 1
                    continue
                }
                val expected = when {
                    byte and 0b1000_0000 == 0 -> 1
                    byte and 0b1110_0000 == 0b1100_0000 -> 2
                    byte and 0b1111_0000 == 0b1110_0000 -> 3
                    byte and 0b1111_1000 == 0b1111_0000 -> 4
                    else -> return 0 // invalid lead — decode lossily now
                }
                val have = back + 1
                return if (have < expected) have else 0
            }
            return 0
        }
    }
}
