import Foundation

/// One step of a proposed multi-step plan.
public struct ToolCall: Sendable, Equatable {
    public let name: String
    public let input: String

    public init(name: String, input: String) {
        self.name = name
        self.input = input
    }
}

/// One planner decision: call a tool, propose a multi-step plan, or give the final answer.
public enum AgentDecision: Sendable, Equatable {
    case useTool(name: String, input: String)
    /// Several tool calls proposed AS ONE UNIT — the user approves the whole plan once
    /// (Milestone 3, the Cowork UX). Never empty (the parser rejects an empty plan).
    case plan([ToolCall])
    case finalAnswer(String)
}

public enum AgentDecisionParser {
    /// Parse the planner's JSON. Accepts any of the shapes, even wrapped in prose
    /// (local models love to add commentary around their JSON):
    ///   `{"tool":"calculator","input":"2+2"}`
    ///   `{"plan":[{"tool":"fs.move","input":"a.txt to Archive"}, …]}`
    ///   `{"answer":"The result is 4."}`
    /// Precedence when several keys appear: answer > plan > tool — identical on both platforms.
    public static func parse(_ raw: String) -> AgentDecision? {
        guard let json = firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let answer = object["answer"] as? String {
            return .finalAnswer(answer)
        }
        if let planItems = object["plan"] as? [[String: Any]] {
            // STRICT: every item needs a nonempty "tool", and an empty plan is no decision —
            // a half-parseable plan must fail loudly, not execute partially.
            let calls = planItems.compactMap { item -> ToolCall? in
                guard let tool = item["tool"] as? String, !tool.isEmpty else { return nil }
                return ToolCall(name: tool, input: item["input"] as? String ?? "")
            }
            guard !calls.isEmpty, calls.count == planItems.count else { return nil }
            return .plan(calls)
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
