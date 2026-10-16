import Foundation

/// Muse output parsing assumes the exact assistant suffix produced by the chat formatter.
/// Raw callers cannot opt into that trust by supplying a special-token prefix themselves.
enum MuseGenerationPolicy {
    enum Request { case raw, chat }

    static func validate(isMuse: Bool, request: Request, hasGrammar: Bool) throws {
        guard isMuse else { return }
        guard request == .chat else {
            throw InferenceError.generationFailed(reason: "Muse Spark requires the structured chat API. Raw prompt generation is unavailable for this model.")
        }
        guard !hasGrammar else {
            throw InferenceError.generationFailed(reason: "Muse Spark structured agent decoding is unavailable in this runtime. Choose another model for structured actions.")
        }
    }
}

/// Text-only subset of llama.cpp's pinned muse-spark.jinja. Low reasoning still permits
/// private reasoning; MuseFinalChannelFilter keeps it out of the user-visible stream.
public enum MuseChatPrompt {
    public static func build(system: String, history: [ChatMessage]) -> String {
        let instructions = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let guide = "Reasoning strength: 16.\nUse to=self for private reasoning and to=user for the final answer."
        var prompt = "<|begin_of_text|><|start|>system<|message|>"
            + escape(instructions.isEmpty ? guide : instructions + "\n\n" + guide) + "<|eot|>"
        for message in history {
            let role = message.role == .user ? "user" : "assistant to=user"
            prompt += "<|start|>\(role)<|message|>\(escape(message.text.trimmingCharacters(in: .whitespacesAndNewlines)))<|eot|>"
        }
        return prompt + "<|start|>assistant"
    }

    public static func escape(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "<|", with: "< |")
        for tag in ["image", "video", "audio"] {
            escaped = escaped.replacingOccurrences(of: "<\(tag)>", with: "< \(tag)>")
        }
        return escaped
    }
}

/// Incremental, bounded protocol parser. Starts after the prompt's `assistant` prefix.
/// Only to=user (or an omitted recipient) may emit text. Hidden/unknown channels, partial
/// headers and special tokens never reach the UI; eom continues into the next message.
public struct MuseFinalChannelFilter: Sendable {
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
                case "", "to=user": visible = true
                case "to=self", "to=commentary": visible = false
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
                case "<|eom|>": state = .nextMessage
                case "<|eot|>": stop()
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
        let tail: String
        if case .body(true) = state, buffer == "<" { tail = buffer }
        else { tail = "" }
        stop()
        return tail
    }

    private mutating func stop() { state = .stopped; isStopped = true; buffer = "" }
}
