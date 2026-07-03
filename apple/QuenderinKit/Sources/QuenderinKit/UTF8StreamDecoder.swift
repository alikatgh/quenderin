import Foundation

/// Decodes a token stream's bytes into text WITHOUT corrupting characters that BPE split
/// across tokens. Every Cyrillic letter is 2 bytes and emoji are 4 — tokenizers cut through
/// them freely, and decoding each token's bytes independently turns the cut halves into
/// U+FFFD "�" garbage mid-stream. This holds incomplete trailing sequences (at most 3 bytes)
/// until their continuation arrives.
///
/// Pure and tiny so it unit-tests exhaustively; Kotlin/JNI twin tracked in
/// docs/KNOWN_FAILURE_MODES.md (Android converts per-piece in JNI today — same bug).
public struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    public init() {}

    /// Feed one token's bytes; returns whatever text is COMPLETE so far.
    public mutating func feed(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let keep = Self.incompleteTailLength(pending)
        let ready = pending.dropLast(keep)
        pending = Array(pending.suffix(keep))
        guard !ready.isEmpty else { return "" }
        return String(decoding: ready, as: UTF8.self)
    }

    /// End of stream: decode whatever is left (lossy for genuinely truncated sequences —
    /// at that point "�" is the honest rendering, not a bug).
    public mutating func flush() -> String {
        defer { pending = [] }
        guard !pending.isEmpty else { return "" }
        return String(decoding: pending, as: UTF8.self)
    }

    /// How many bytes at the END of `bytes` are the start of a NOT-YET-COMPLETE UTF-8
    /// character (0 when the buffer ends on a character boundary). Looks back at most
    /// 3 bytes — the longest possible incomplete prefix of a 4-byte sequence.
    static func incompleteTailLength(_ bytes: [UInt8]) -> Int {
        var back = 0
        while back < 3, back < bytes.count {
            let byte = bytes[bytes.count - 1 - back]
            if byte & 0b1100_0000 == 0b1000_0000 {   // continuation byte — keep looking for its lead
                back += 1
                continue
            }
            // `byte` is a lead (or ASCII, or invalid). How long a sequence does it claim?
            let expected: Int
            if byte & 0b1000_0000 == 0 { expected = 1 }
            else if byte & 0b1110_0000 == 0b1100_0000 { expected = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { expected = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { expected = 4 }
            else { return 0 }   // invalid lead — let lossy decoding handle it now
            let have = back + 1
            return have < expected ? have : 0   // incomplete → hold; complete/overlong → decode now
        }
        return 0   // 3+ continuation bytes with no lead in reach — malformed; decode lossily now
    }
}
