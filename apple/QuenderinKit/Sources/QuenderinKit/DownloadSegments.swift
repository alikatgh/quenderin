import Foundation

/// Splits a download into disjoint byte ranges for parallel fetching, and maps per-segment
/// progress back to whole-file progress. Pure (no networking, no files) so it unit-tests in
/// milliseconds — the risky part of a parallel downloader is the arithmetic, not the sockets.
///
/// Why parallel at all: a single TCP stream is capped by `RTT × window`. Against a distant CDN
/// (e.g. HuggingFace's Xet bridge on a US edge from Asia) one stream uses roughly half the link;
/// N concurrent `Range:` requests use the whole pipe. See `docs/` on the download path.
public struct DownloadSegments: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let index: Int
        /// Inclusive first byte.
        public let start: Int64
        /// Inclusive last byte.
        public let end: Int64
        public var length: Int64 { end - start + 1 }

        public init(index: Int, start: Int64, end: Int64) {
            self.index = index
            self.start = start
            self.end = end
        }
    }

    public let total: Int64
    public let segments: [Segment]

    /// Even split with the remainder spread over the first segments, so the union is exactly
    /// `[0, total)` with no gaps or overlaps. Never more segments than bytes.
    public init(totalBytes: Int64, segmentCount: Int) {
        precondition(totalBytes > 0, "segment plan needs a known, positive size")
        let n = Int(Swift.max(1, Swift.min(Int64(segmentCount), totalBytes)))
        let base = totalBytes / Int64(n)
        let remainder = totalBytes % Int64(n)
        var segs: [Segment] = []
        var start: Int64 = 0
        for i in 0..<n {
            let len = base + (Int64(i) < remainder ? 1 : 0)
            segs.append(Segment(index: i, start: start, end: start + len - 1))
            start += len
        }
        self.total = totalBytes
        self.segments = segs
    }

    /// How many parallel connections to open. Scales with size (~1 per 32 MB) so a small model
    /// isn't fanned out pointlessly, and is deliberately lower on cellular (money + battery).
    public static func connectionCount(totalBytes: Int64, isCellular: Bool, max: Int = 6) -> Int {
        guard totalBytes > 0 else { return 1 }
        let perSegment: Int64 = 32 << 20
        let bySize = Int((totalBytes + perSegment - 1) / perSegment)
        let ceiling = isCellular ? Swift.min(3, max) : max
        return Swift.max(1, Swift.min(ceiling, bySize))
    }

    /// The whole-file fraction (0...1) for a per-segment downloaded-byte vector. Extra bytes beyond
    /// a segment's length are ignored, so a mis-sized response can never push progress past 1.0.
    public func fraction(downloadedPerSegment: [Int64]) -> Double {
        guard total > 0 else { return 0 }
        var done: Int64 = 0
        for (i, seg) in segments.enumerated() {
            let have = i < downloadedPerSegment.count ? downloadedPerSegment[i] : 0
            done += Swift.min(seg.length, Swift.max(0, have))
        }
        return Double(done) / Double(total)
    }
}
