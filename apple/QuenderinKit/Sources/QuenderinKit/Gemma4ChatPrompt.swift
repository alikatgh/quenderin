import Foundation

/// Text-only, thinking-disabled Gemma 4 turns. llama.cpp's C chat-template API
/// does not yet interpret Gemma 4's Jinja template; falling back to a flat
/// transcript exposes channel markers and loses the model's role boundaries.
/// Matches models/templates/google-gemma-4-31B-it.jinja in the pinned llama.cpp.
enum Gemma4ChatPrompt {
    static func make(template: String, system: String, history: [ChatMessage]) -> String? {
        guard template.contains("<|turn>"), template.contains("<|channel>") else { return nil }
        var result = "" // The tokenizer adds BOS.
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { result += "<|turn>system\n\(system)<turn|>\n" }
        for message in history {
            let role = message.role == .user ? "user" : "model"
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result += "<|turn>\(role)\n\(text)<turn|>\n"
        }
        return result + "<|turn>model\n<|channel>thought\n<channel|>"
    }
}
