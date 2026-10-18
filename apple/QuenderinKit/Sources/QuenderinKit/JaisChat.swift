import Foundation

/// Starts inside Jais 3's mandatory private reasoning segment. The low/medium modes
/// sometimes use the generic closer; all publisher-supported closers are accepted.
public struct JaisFinalChannelFilter: Sendable {
    private var pending = ""
    private var hidden = true
    public private(set) var isStopped = false
    private let closers = ["</ifm|think>", "</ifm|think_faster>", "</ifm|think_fast>"]
    private let openers = ["<ifm|think>", "<ifm|think_faster>", "<ifm|think_fast>"]
    private let ends = ["<|ifm|im_end|>", "<|ifm|im_start|>", "<|end_of_text|>"]
    public init() {}

    public mutating func feed(_ text: String) -> String {
        guard !isStopped else { return "" }
        pending += text
        var output = ""
        while !pending.isEmpty {
            let tokens = (hidden ? closers : openers) + ends
            let found = tokens.compactMap { token -> (String, Range<String.Index>)? in
                pending.range(of: token).map { (token, $0) }
            }.min { $0.1.lowerBound < $1.1.lowerBound }
            if let (token, range) = found {
                if !hidden { output += pending[..<range.lowerBound] }
                pending.removeSubrange(..<range.upperBound)
                if ends.contains(token) { isStopped = true; pending = ""; break }
                hidden.toggle()
            } else {
                var held = 0
                for token in tokens {
                    for count in 1..<token.count where count <= pending.count {
                        if pending.hasSuffix(token.prefix(count)) { held = max(held, count) }
                    }
                }
                if !hidden { output += pending.dropLast(held) }
                pending = String(pending.suffix(held))
                break
            }
        }
        return output
    }
    public mutating func finish() -> String { pending = ""; isStopped = true; return "" }
}
