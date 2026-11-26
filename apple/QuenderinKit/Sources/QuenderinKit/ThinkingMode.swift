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

    private static let openTagBytes: [UInt8] = Array("<think>".utf8)
    private static let closeTagBytes: [UInt8] = Array("</think>".utf8)
    private static let turnBoundaryMarkers: [[UInt8]] = [
        Array("<|im_start|>assistant".utf8),
        Array("<|im_end|>".utf8),
        Array("<|start_header_id|>assistant<|end_header_id|>".utf8),
        Array("<|eot_id|>".utf8),
        Array("<start_of_turn>model".utf8),
        Array("<start_of_turn>assistant".utf8),
        Array("<end_of_turn>".utf8),
        Array("<｜Assistant｜>".utf8),
        Array("<|Assistant|>".utf8),
        Array("<|assistant|>".utf8),
        Array("<|end|>".utf8),
        Array("[/INST]".utf8),
        Array("</s>".utf8),
        Array("\nAssistant:".utf8),
        Array("\nassistant:".utf8),
        Array("\rAssistant:".utf8),
        Array("\rassistant:".utf8),
    ]
    private static let leadingAssistantMarkers: [[UInt8]] = [
        Array("Assistant:".utf8),
        Array("assistant:".utf8),
    ]

    /// Returns true when `text` contains a `<think>` tag that is not closed by a later `</think>`.
    /// Operates on raw UTF-8 bytes so combining marks never coalesce with tag characters.
    /// Twin of Android `ThinkingMode.hasUnclosedThinkTag`.
    public static func hasUnclosedThinkTag(in text: String) -> Bool {
        hasUnclosedThinkTag(in: Array(text.utf8)[...])
    }

    /// Returns true when the current assistant generation prefix of `prompt` leaves an unclosed
    /// `<think>` block — including prefixes with text after `<think>` (e.g. `<think>\nReasoning: `)
    /// — while ignoring literal `<think>` tags inside earlier user/system messages.
    /// When `withoutAssistantPrefix` (the template rendered with `add_ass = false`) is a bytewise
    /// prefix of `prompt`, only the exact assistant-prefix suffix is inspected.
    /// Twin of Android `ThinkingMode.promptEndsInsideThinking`.
    public static func promptEndsInsideThinking(_ prompt: String, withoutAssistantPrefix: String) -> Bool {
        let pBytes = Array(prompt.utf8)
        let bBytes = Array(withoutAssistantPrefix.utf8)
        if !bBytes.isEmpty && pBytes.count >= bBytes.count && bytesStartWith(pBytes[...], prefix: bBytes) {
            return hasUnclosedThinkTag(in: pBytes[bBytes.count...])
        }
        return promptEndsInsideThinking(prompt)
    }

    /// Returns true when a rendered chat prompt's current assistant prefix leaves an unclosed
    /// `<think>` block (even if non-empty text such as `Reasoning: ` follows `<think>`), while
    /// ignoring literal `<think>` tags in earlier user messages.
    /// Operates on raw UTF-8 bytes so combining marks never coalesce with tag characters.
    /// Twin of Android `ThinkingMode.promptEndsInsideThinking`.
    public static func promptEndsInsideThinking(_ prompt: String) -> Bool {
        let bytes = Array(prompt.utf8)
        guard !bytes.isEmpty else { return false }

        var boundaryEnd: Int? = nil
        for marker in turnBoundaryMarkers {
            if let idx = lastIndexOf(marker, in: bytes) {
                let end = idx + marker.count
                if boundaryEnd == nil || end > boundaryEnd! {
                    boundaryEnd = end
                }
            }
        }
        for leading in leadingAssistantMarkers {
            if bytesStartWith(bytes[...], prefix: leading) {
                if boundaryEnd == nil || leading.count > boundaryEnd! {
                    boundaryEnd = leading.count
                }
            }
        }

        if let boundaryEnd {
            return hasUnclosedThinkTag(in: bytes[boundaryEnd...])
        }

        // Standalone prefix with no turn marker: treat as pre-opened only if it starts with
        // optional ASCII whitespace followed by `<think>` and leaves `<think>` unclosed.
        var start = 0
        while start < bytes.count {
            let b = bytes[start]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                start += 1
            } else {
                break
            }
        }
        let trimmed = bytes[start...]
        guard bytesStartWith(trimmed, prefix: openTagBytes) else { return false }
        return hasUnclosedThinkTag(in: trimmed)
    }

    private static func hasUnclosedThinkTag(in slice: ArraySlice<UInt8>) -> Bool {
        guard let lastOpen = lastIndexOf(openTagBytes, in: slice) else { return false }
        guard let lastClose = lastIndexOf(closeTagBytes, in: slice) else { return true }
        return lastClose < lastOpen
    }

    private static func bytesStartWith(_ haystack: ArraySlice<UInt8>, prefix: [UInt8]) -> Bool {
        guard haystack.count >= prefix.count else { return false }
        var hi = haystack.startIndex
        for pi in 0..<prefix.count {
            if haystack[hi] != prefix[pi] { return false }
            hi += 1
        }
        return true
    }

    private static func lastIndexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        lastIndexOf(needle, in: haystack[...])
    }

    private static func lastIndexOf(_ needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
        let n = needle.count
        guard n > 0, haystack.count >= n else { return nil }
        let start = haystack.startIndex
        let lastStart = haystack.endIndex - n
        var i = lastStart
        while i >= start {
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
            if i == start { break }
            i -= 1
        }
        return nil
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

    /// Initializes the splitter from the rendered prompt sent to the model: an unclosed trailing
    /// `<think>` starts inside the thinking state so pre-opened templates never leak reasoning
    /// into the visible answer.
    public init(renderedPrompt: String) {
        self.init(startsInsideThinking: ThinkingMode.promptEndsInsideThinking(renderedPrompt))
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
