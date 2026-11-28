import Foundation

/// Streams generated text while watching for a stop sequence that may span token boundaries.
///
/// `GenerationOptions.stopSequences` was defined but never consumed by the decode loop — set it and
/// the model ran to `maxTokens` regardless (dead field; caught by the Qwen3 runtime audit). This
/// makes it real: the decode loop feeds each piece through the scanner, which holds back a suffix
/// only while it matches the start of an exact stop sequence. When a full sequence appears, it returns the text
/// up to the stop and signals halt — so `"…thought</think>"` emits `"…thought"` and stops there,
/// even though `</think>` arrived as several tokens.
///
/// It's the enabling piece for a "think, then decide" agent pass (stop at `</think>`). Inert when no
/// stop sequences are set, so every existing caller is byte-for-byte unchanged.
struct StopSequenceScanner {
    private let stops: [Data]
    /// Text seen but not yet safe to emit (could be a partial stop-sequence tail).
    private var buffer = Data()

    init(stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }.map { Data($0.utf8) }
    }

    /// False when there are no stop sequences — the caller then yields pieces directly (zero overhead).
    var isActive: Bool { !stops.isEmpty }

    /// Feed the next decoded piece. Returns the text safe to emit now, and whether a stop sequence
    /// completed (the caller should then halt generation).
    mutating func feed(_ piece: String) -> (emit: String, stop: Bool) {
        guard isActive else { return (piece, false) }
        buffer.append(contentsOf: piece.utf8)
        if let start = stops.compactMap({ buffer.range(of: $0)?.lowerBound }).min() {
            let emit = String(decoding: buffer[..<start], as: UTF8.self)
            buffer.removeAll()
            return (emit, true)
        }
        var held = 0
        for stop in stops {
            var length = min(buffer.count, stop.count - 1)
            while length > held {
                if buffer.suffix(length).elementsEqual(stop.prefix(length)) {
                    held = length
                    break
                }
                length -= 1
            }
        }
        let emit = String(decoding: buffer.dropLast(held), as: UTF8.self)
        buffer = Data(buffer.suffix(held))
        return (emit, false)
    }

    /// End of stream with no stop matched — release whatever was held back.
    mutating func flush() -> String {
        let out = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return out
    }
}
