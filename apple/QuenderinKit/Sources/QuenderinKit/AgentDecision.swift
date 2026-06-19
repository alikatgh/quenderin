import Foundation

/// One planner decision: call a tool, or give the final answer.
public enum AgentDecision: Sendable, Equatable {
    case useTool(name: String, input: String)
    case finalAnswer(String)
}

public enum AgentDecisionParser {
    /// Parse the planner's JSON. Accepts either shape, even when wrapped in prose
    /// (local models love to add commentary around their JSON):
    ///   `{"tool":"calculator","input":"2+2"}`
    ///   `{"answer":"The result is 4."}`
    public static func parse(_ raw: String) -> AgentDecision? {
        guard let json = firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let answer = object["answer"] as? String {
            return .finalAnswer(answer)
        }
        if let tool = object["tool"] as? String, !tool.isEmpty {
            return .useTool(name: tool, input: object["input"] as? String ?? "")
        }
        return nil
    }

    /// Extract the FIRST complete, balanced `{ ... }` object from surrounding text. Walking braces
    /// (and skipping quoted strings) instead of first-`{`..last-`}` stops a second JSON object in the
    /// same response from being merged in — which made Kotlin return a premature/injected answer
    /// while Swift returned planError (H13, a parity break). Now both take the first object.
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
