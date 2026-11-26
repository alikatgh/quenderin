import Foundation

/// Controls how reasoning models (Qwen3, DeepSeek-R1, …) handle `<think>…</think>` chains.
/// Semantics mirror Ollama's `think` / `--hidethinking`:
/// - `off`: default today — the chat template closes an empty think block for direct replies.
/// - `show`: model is allowed to think; thinking text is shown collapsed above the answer.
/// - `hide`: model is allowed to think; only the answer is shown.
/// Pure Foundation + deterministic → testable on Linux. Twin of Android `ThinkingMode`.
public enum ThinkingMode: String, Sendable, Equatable, Codable, CaseIterable {
    case off = "off"
    case show = "show"
    case hide = "hide"

    public static let defaultMode: ThinkingMode = .off

    /// Whether the model is allowed to emit reasoning inside `<think>…</think>`.
    public var allowsThinking: Bool {
        switch self {
        case .off:
            return false
        case .show, .hide:
            return true
        }
    }

    /// Returns true when a GGUF chat template gates reasoning via `enable_thinking` or `<think>`.
    /// Shared by `LlamaEngine` so template detection stays consistent across call sites.
    public static func supports(template: String) -> Bool {
        template.contains("enable_thinking") || template.contains("<think>")
    }

    /// Returns true when the chat prompt builder should close an empty `<think>` block after the
    /// assistant turn: only when `mode` disallows thinking (`.off`) AND the template supports it.
    /// Twin of Android `ThinkingMode.shouldCloseThinkBlock`.
    public static func shouldCloseThinkBlock(mode: ThinkingMode, template: String) -> Bool {
        !mode.allowsThinking && supports(template: template)
    }
}

/// Streaming splitter that separates `<think>…</think>` reasoning from the visible answer across
/// arbitrary token boundaries. Holds back only a possible partial tag suffix (like
/// `StopSequenceScanner`), holds leading ASCII whitespace at stream start until the first
/// non-whitespace scalar (dropping it if `<think>` immediately follows, or preserving it in
/// `answer` otherwise), routes every `<think>…</think>` block anywhere in the stream (even after a
/// preamble or across multiple blocks) into `thinking`, supports pre-opened templates
/// (`startsInsideThinking`), routes unclosed thinking to `thinking` on `finish()`, and operates on
/// raw UTF-8 bytes so combining marks following tag boundaries never coalesce into grapheme
/// clusters and chunk boundaries never affect results.
/// Pure Foundation + deterministic → testable on Linux. Twin of Android `ThinkingSplitter`.
public struct ThinkingSplitter: Sendable, Equatable {
    private static let openTag: [UInt8] = Array("<think>".utf8)
    private static let closeTag: [UInt8] = Array("</think>".utf8)

    private enum State: Sendable, Equatable {
        case awaitingInitialOpen
        case outside
        case thinking
        case finished
    }

    private var state: State
    private var buffer: [UInt8] = []

    public init(startsInsideThinking: Bool = false) {
        self.state = startsInsideThinking ? .thinking : .awaitingInitialOpen
    }

    /// True while the splitter is currently inside a `<think>…</think>` block.
    public var isThinking: Bool {
        state == .thinking
    }

    /// Feed the next streamed text piece. Returns incremental `(thinking, answer)` deltas.
    public mutating func feed(_ piece: String) -> (thinking: String, answer: String) {
        guard !piece.isEmpty, state != .finished else { return ("", "") }
        buffer.append(contentsOf: piece.utf8)
        return drain()
    }

    /// Flush any held-back text at end of stream. Unclosed thinking flushes to `thinking` with
    /// an empty `answer`; unconfirmed pre-open or trailing partial open-tag text flushes to `answer`.
    public mutating func finish() -> (thinking: String, answer: String) {
        let pending = buffer.isEmpty ? "" : String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        switch state {
        case .thinking:
            state = .finished
            return (pending, "")
        case .awaitingInitialOpen, .outside:
            state = .finished
            return ("", pending)
        case .finished:
            return ("", "")
        }
    }

    // MARK: - Internal state helpers

    private mutating func drain() -> (thinking: String, answer: String) {
        var thinkingBytes: [UInt8] = []
        var answerBytes: [UInt8] = []

        loop: while !buffer.isEmpty {
            switch state {
            case .finished:
                break loop

            case .awaitingInitialOpen:
                var idx = 0
                while idx < buffer.count && Self.isASCIIWhitespace(buffer[idx]) {
                    idx += 1
                }
                // Only whitespace seen so far — hold until we know whether `<think>` follows.
                if idx == buffer.count {
                    break loop
                }

                let rem = buffer[idx...]
                if Self.startsWith(rem, prefix: Self.openTag) {
                    // Drop leading whitespace and `<think>`, switch into thinking mode.
                    buffer = Array(buffer[(idx + Self.openTag.count)...])
                    state = .thinking
                    continue loop
                }
                if Self.startsWith(Self.openTag[...], prefix: rem) {
                    // Partial `<think>` prefix after leading whitespace — wait for more bytes.
                    break loop
                }

                // First non-whitespace cannot be an opening `<think>`: preserve leading whitespace
                // and scan the buffer in `.outside` mode so any later `<think>` is still split out.
                state = .outside
                continue loop

            case .outside:
                if let openIdx = Self.indexOf(Self.openTag, in: buffer) {
                    if openIdx > 0 {
                        answerBytes.append(contentsOf: buffer[..<openIdx])
                    }
                    buffer = Array(buffer[(openIdx + Self.openTag.count)...])
                    state = .thinking
                    continue loop
                }

                // Hold back only the longest suffix that could be a prefix of `<think>`.
                let holdLen = Self.longestPrefixSuffixLength(of: buffer, matchingPrefixOf: Self.openTag)
                let emitCount = buffer.count - holdLen
                if emitCount > 0 {
                    answerBytes.append(contentsOf: buffer[..<emitCount])
                    buffer = Array(buffer[emitCount...])
                }
                break loop

            case .thinking:
                if let closeIdx = Self.indexOf(Self.closeTag, in: buffer) {
                    if closeIdx > 0 {
                        thinkingBytes.append(contentsOf: buffer[..<closeIdx])
                    }
                    buffer = Array(buffer[(closeIdx + Self.closeTag.count)...])
                    state = .outside
                    continue loop
                }

                // Hold back only the longest suffix that could be a prefix of `</think>`.
                let holdLen = Self.longestPrefixSuffixLength(of: buffer, matchingPrefixOf: Self.closeTag)
                let emitCount = buffer.count - holdLen
                if emitCount > 0 {
                    thinkingBytes.append(contentsOf: buffer[..<emitCount])
                    buffer = Array(buffer[emitCount...])
                }
                break loop
            }
        }

        let thinking = thinkingBytes.isEmpty ? "" : String(decoding: thinkingBytes, as: UTF8.self)
        let answer = answerBytes.isEmpty ? "" : String(decoding: answerBytes, as: UTF8.self)
        return (thinking, answer)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func startsWith<S1: RandomAccessCollection, S2: RandomAccessCollection>(
        _ haystack: S1,
        prefix: S2
    ) -> Bool where S1.Element == UInt8, S2.Element == UInt8 {
        guard haystack.count >= prefix.count else { return false }
        var i1 = haystack.startIndex
        var i2 = prefix.startIndex
        while i2 < prefix.endIndex {
            if haystack[i1] != prefix[i2] { return false }
            i1 = haystack.index(after: i1)
            i2 = prefix.index(after: i2)
        }
        return true
    }

    private static func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        let n = needle.count
        guard n > 0, haystack.count >= n else { return nil }
        let lastStart = haystack.count - n
        var i = 0
        while i <= lastStart {
            if haystack[i] == needle[0] {
                var matched = true
                var j = 1
                while j < n {
                    if haystack[i + j] != needle[j] {
                        matched = false
                        break
                    }
                    j += 1
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    /// Length of the longest proper non-empty suffix of `bytes` that is a prefix of `tag`.
    private static func longestPrefixSuffixLength(of bytes: [UInt8], matchingPrefixOf tag: [UInt8]) -> Int {
        let maxLen = min(bytes.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        let base = bytes.count
        for len in stride(from: maxLen, through: 1, by: -1) {
            let start = base - len
            var matched = true
            var j = 0
            while j < len {
                if bytes[start + j] != tag[j] {
                    matched = false
                    break
                }
                j += 1
            }
            if matched { return len }
        }
        return 0
    }
}
