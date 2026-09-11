package ai.quenderin.core

/**
 * Pure segment arithmetic for the parallel download path — the Kotlin twin of Swift
 * `DownloadSegments`. Splits a known-size file into disjoint `Range:` segments and maps
 * per-segment progress back to a whole-file fraction. No I/O, no threads, so it verifies
 * in the headless harness.
 *
 * Why parallel: one TCP stream is capped by `RTT x window`, so a single connection to a
 * distant CDN uses roughly half the link; N concurrent range requests use the pipe.
 */
object DownloadSegments {

    data class Segment(val index: Int, val start: Long, val end: Long) {
        /** Inclusive length in bytes. */
        val length: Long get() = end - start + 1
    }

    data class Plan(val total: Long, val segments: List<Segment>)

    /** Even split with the remainder on the first segments — the union is exactly `[0, total)`. */
    fun plan(totalBytes: Long, segmentCount: Int): Plan {
        require(totalBytes > 0) { "segment plan needs a known, positive size" }
        val n = maxOf(1, minOf(segmentCount.toLong(), totalBytes)).toInt()
        val base = totalBytes / n
        val remainder = totalBytes % n
        val segments = ArrayList<Segment>(n)
        var start = 0L
        for (i in 0 until n) {
            val len = base + if (i < remainder) 1 else 0
            segments.add(Segment(i, start, start + len - 1))
            start += len
        }
        return Plan(totalBytes, segments)
    }

    /**
     * How many parallel connections to open. Scales with size (~1 per 32 MB) so a small model
     * isn't fanned out pointlessly, and is lower on cellular (money + battery).
     */
    fun connectionCount(totalBytes: Long, isCellular: Boolean, max: Int = 6): Int {
        if (totalBytes <= 0) return 1
        val perSegment = 32L shl 20
        val bySize = ((totalBytes + perSegment - 1) / perSegment).toInt()
        val ceiling = if (isCellular) minOf(3, max) else max
        return maxOf(1, minOf(ceiling, bySize))
    }

    /** Whole-file fraction (0...1); extra bytes beyond a segment are ignored, so never > 1.0. */
    fun fraction(plan: Plan, downloadedPerSegment: LongArray): Double {
        if (plan.total <= 0) return 0.0
        var done = 0L
        plan.segments.forEachIndexed { i, seg ->
            val have = if (i < downloadedPerSegment.size) downloadedPerSegment[i] else 0L
            done += minOf(seg.length, maxOf(0L, have))
        }
        return done.toDouble() / plan.total
    }
}
