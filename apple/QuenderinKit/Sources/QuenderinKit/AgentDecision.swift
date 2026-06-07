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

    /// Extract the outermost `{ ... }` from surrounding text.
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
