import Foundation

/// Streams generated text while watching for a stop sequence that may span token boundaries.
///
/// `GenerationOptions.stopSequences` was defined but never consumed by the decode loop — set it and
/// the model ran to `maxTokens` regardless (dead field; caught by the Qwen3 runtime audit). This
/// makes it real: the decode loop feeds each piece through the scanner, which HOLDS BACK the last
/// `maxStopLen-1` characters (they could be the start of a stop sequence split across tokens) and
/// emits only text that can't be part of one. When a full stop sequence appears, it returns the text
/// up to the stop and signals halt — so `"…thought</think>"` emits `"…thought"` and stops there,
/// even though `</think>` arrived as several tokens.
///
/// It's the enabling piece for a "think, then decide" agent pass (stop at `</think>`). Inert when no
/// stop sequences are set, so every existing caller is byte-for-byte unchanged.
struct StopSequenceScanner {
    private let stops: [String]
    private let maxLen: Int
    /// Text seen but not yet safe to emit (could be a partial stop-sequence tail).
    private var buffer = ""

    init(stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }
        self.maxLen = self.stops.map(\.count).max() ?? 0
    }

    /// False when there are no stop sequences — the caller then yields pieces directly (zero overhead).
    var isActive: Bool { !stops.isEmpty }

    /// Feed the next decoded piece. Returns the text safe to emit now, and whether a stop sequence
    /// completed (the caller should then halt generation).
    mutating func feed(_ piece: String) -> (emit: String, stop: Bool) {
        guard maxLen > 0 else { return (piece, false) }   // no stops → passthrough (and never suffix(-1))
        buffer += piece
        if let r = firstStopRange() {
            let emit = String(buffer[buffer.startIndex..<r.lowerBound])
            buffer = ""
            return (emit, true)
        }
        // Nothing matched yet: emit everything except a possible partial-stop tail.
        guard buffer.count >= maxLen else { return ("", false) }
        let safeCount = buffer.count - (maxLen - 1)
        let emit = String(buffer.prefix(safeCount))
        buffer = String(buffer.suffix(maxLen - 1))
        return (emit, false)
    }

    /// End of stream with no stop matched — release whatever was held back.
    mutating func flush() -> String {
        let out = buffer
        buffer = ""
        return out
    }

    private func firstStopRange() -> Range<String.Index>? {
        var best: Range<String.Index>?
        for s in stops {
            if let r = buffer.range(of: s), best == nil || r.lowerBound < best!.lowerBound {
                best = r
            }
        }
        return best
    }
}
