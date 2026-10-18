import Foundation

/// Exact text-only subset of Reflection's pinned Harmony XML template, minimal effort=8.
/// Native ChatMessage persists final text only. This explicitly chooses the publisher's
/// allow_missing_thinking=true policy: restored assistant turns receive empty analysis.
public enum BeamChatPrompt {
    public static let allowMissingThinking = true
    public static func build(system: String, history: [ChatMessage]) -> String {
        var prompt = "<|start|>system<|message|>You are Beam, an AI assistant trained by Reflection.\n\nReasoning effort: 8"
            + "\n\n# Valid channels: analysis, final. Channel must be included for every message.<|end|>"
        if !system.isEmpty {
            prompt += "<|start|>developer<|message|># Instructions\n\n" + escape(system) + "<|end|>"
        }
        for message in history {
            if message.role == .user {
                prompt += "<|start|>user<|message|>" + escape(message.text) + "<|end|>"
            } else {
                prompt += "<|start|>assistant<|channel|>analysis<|message|><|end|>"
                    + "<|start|>assistant<|channel|>final<|message|>" + escape(message.text) + "<|return|>"
            }
        }
        return prompt + "<|start|>assistant"
    }
    public static func escape(_ text: String) -> String { text.replacingOccurrences(of: "<|", with: "< |") }
}

/// Only an explicit final channel may emit. Bounded split markers and unknown/tools fail closed.
public struct BeamFinalChannelFilter: Sendable {
    private enum State: Sendable { case header, body(Bool), nextMessage, stopped }
    private var state: State = .header
    private var buffer = ""
    public private(set) var isStopped = false
    public init() {}

    public mutating func feed(_ text: String) -> String {
        guard !isStopped else { return "" }
        buffer += text
        var output = ""
        while !buffer.isEmpty, !isStopped {
            switch state {
            case .header:
                guard let delimiter = buffer.range(of: "<|message|>") else {
                    if buffer.utf8.count > 1024 { stop() }
                    return output
                }
                guard buffer[..<delimiter.lowerBound].utf8.count <= 1024 else { stop(); return output }
                let header = String(buffer[..<delimiter.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let visible: Bool
                switch header {
                case "<|channel|>final": visible = true
                case "<|channel|>analysis": visible = false
                default: stop(); return output // tools and unknown protocol fail closed
                }
                buffer.removeSubrange(..<delimiter.upperBound)
                state = .body(visible)
            case .body(let visible):
                guard let start = buffer.range(of: "<|") else {
                    // Hold '<' across chunks so no special-token prefix can leak.
                    let held = buffer.hasSuffix("<") ? "<" : ""
                    let count = buffer.count - held.count
                    if visible { output += buffer.prefix(count) }
                    buffer = held
                    return output
                }
                if visible { output += buffer[..<start.lowerBound] }
                buffer.removeSubrange(..<start.lowerBound)
                guard let end = buffer.range(of: "|>") else {
                    if buffer.utf8.count > 128 { stop() }
                    return output
                }
                let token = String(buffer[..<end.upperBound])
                buffer.removeSubrange(..<end.upperBound)
                switch token {
                case "<|end|>": state = .nextMessage
                case "<|return|>": stop()
                default: stop()
                }
            case .nextMessage:
                let prefix = "<|start|>assistant"
                guard buffer.count >= prefix.count else {
                    if !prefix.hasPrefix(buffer) { stop() }
                    return output
                }
                guard buffer.hasPrefix(prefix) else { stop(); return output }
                buffer.removeFirst(prefix.count)
                state = .header
            case .stopped: return output
            }
        }
        return output
    }

    /// An incomplete channel/header is discarded even if generation reaches its token limit.
    public mutating func finish() -> String {
        stop()
        return ""
    }

    private mutating func stop() { state = .stopped; isStopped = true; buffer = "" }
}
