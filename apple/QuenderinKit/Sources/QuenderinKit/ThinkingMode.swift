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
}

/// Streaming splitter that separates `<think>…</think>` reasoning from the visible answer across
/// arbitrary token boundaries. Holds back only a possible partial tag suffix (like
/// `StopSequenceScanner`), holds leading ASCII whitespace until the first non-whitespace scalar
/// (dropping it if `<think>` follows, or emitting it verbatim into `answer` otherwise), supports
/// pre-opened templates (`startsInsideThinking`), routes unclosed thinking to `thinking` on
/// `finish()`, and passes non-thinking output straight through to `answer`.
/// Pure Foundation + deterministic → testable on Linux. Twin of Android `ThinkingSplitter`.
public struct ThinkingSplitter: Sendable, Equatable {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private enum State: Sendable, Equatable {
        case awaitingOpen
        case thinking
        case answer
        case finished
    }

    private var state: State
    private var buffer: String = ""

    public init(startsInsideThinking: Bool = false) {
        self.state = startsInsideThinking ? .thinking : .awaitingOpen
    }

    /// True while the splitter is currently inside a `<think>…</think>` block.
    public var isThinking: Bool {
        state == .thinking
    }

    /// Feed the next streamed text piece. Returns incremental `(thinking, answer)` deltas.
    public mutating func feed(_ piece: String) -> (thinking: String, answer: String) {
        guard !piece.isEmpty else { return ("", "") }

        switch state {
        case .finished:
            return ("", "")

        case .answer:
            return ("", piece)

        case .thinking:
            buffer += piece
            return drainThinking()

        case .awaitingOpen:
            buffer += piece
            return drainAwaitingOpen()
        }
    }

    /// Flush any held-back text at end of stream. Unclosed thinking flushes to `thinking` with
    /// an empty `answer`; unconfirmed pre-open text (no `<think>` ever arrived) flushes to `answer`.
    public mutating func finish() -> (thinking: String, answer: String) {
        let pending = buffer
        buffer = ""
        switch state {
        case .thinking:
            state = .finished
            return (pending, "")
        case .awaitingOpen:
            state = .finished
            return ("", pending)
        case .answer, .finished:
            state = .finished
            return ("", "")
        }
    }

    // MARK: - Internal state helpers

    private mutating func drainAwaitingOpen() -> (thinking: String, answer: String) {
        // Skip ASCII whitespace prefix by Unicode scalar (NOT Character, because Swift treats
        // "\r\n" as a single extended grapheme cluster). Dropped if `<think>` follows, preserved
        // verbatim in `answer` otherwise.
        let scalars = buffer.unicodeScalars
        var idx = scalars.startIndex
        while idx < scalars.endIndex && Self.isASCIIWhitespace(scalars[idx]) {
            idx = scalars.index(after: idx)
        }
        // Only whitespace seen so far — hold until we know whether `<think>` follows.
        if idx == scalars.endIndex {
            return ("", "")
        }

        let remainder = String(scalars[idx...])
        if remainder.hasPrefix(Self.openTag) {
            // Drop leading whitespace and `<think>`, switch into thinking mode, and process tail.
            let afterOpen = remainder.index(remainder.startIndex, offsetBy: Self.openTag.count)
            buffer = String(remainder[afterOpen...])
            state = .thinking
            return drainThinking()
        }

        if Self.openTag.hasPrefix(remainder) {
            // Partial `<think>` prefix at the end of the buffer — wait for more characters.
            return ("", "")
        }

        // First non-whitespace text cannot be `<think>`: emit buffered whitespace + text verbatim.
        let out = buffer
        buffer = ""
        state = .answer
        return ("", out)
    }

    private mutating func drainThinking() -> (thinking: String, answer: String) {
        if let closeRange = buffer.range(of: Self.closeTag, options: .literal) {
            let thinkText = String(buffer[..<closeRange.lowerBound])
            let answerText = String(buffer[closeRange.upperBound...])
            buffer = ""
            state = .answer
            return (thinkText, answerText)
        }

        // Hold back the longest suffix that could be a prefix of `</think>`.
        let holdLen = Self.longestPrefixSuffixLength(of: buffer, matchingPrefixOf: Self.closeTag)
        let emitCount = buffer.count - holdLen
        guard emitCount > 0 else { return ("", "") }

        let splitIndex = buffer.index(buffer.startIndex, offsetBy: emitCount)
        let thinkText = String(buffer[..<splitIndex])
        buffer = String(buffer[splitIndex...])
        return (thinkText, "")
    }

    private static func isASCIIWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
    }

    /// Length of the longest proper non-empty suffix of `text` that is a prefix of `tag`.
    private static func longestPrefixSuffixLength(of text: String, matchingPrefixOf tag: String) -> Int {
        let maxLen = min(text.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            if text.suffix(len) == tag.prefix(len) {
                return len
            }
        }
        return 0
    }
}
