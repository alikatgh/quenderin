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
    /// Tool names that mean the model copied a prompt TEMPLATE instead of a real tool id
    /// (live-caught: Llama 1B emitted `{"tool":"<name>","input":"<text>"}` and stalled).
    /// Treat as parse failure so the loop nudges with the real catalog, not "No such tool: <name>".
    public static func isPlaceholderToolName(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return true }
        // Angle-bracket slots and bare template tokens from our own preamble examples.
        if t.hasPrefix("<") && t.hasSuffix(">") { return true }
        if t.contains("<") || t.contains(">") { return true }
        switch t {
        case "name", "tool", "text", "input", "tool_name", "toolname",
             "<name>", "<tool>", "<text>", "<input>":
            return true
        default:
            return false
        }
    }

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
        if let planItems = object["plan"] as? [Any] {
            // STRICT and AUTHORITATIVE: a top-level "plan" array is THE decision — any non-object
            // member, missing/empty "tool", or empty array is a parse failure (nil), NEVER a
            // fall-through to the top-level "tool" key. The old cast to [[String: Any]] nil'd on a
            // MIXED array ([{…}, "garbage"]) and fell through to `tool`, so the same garbled output
            // ran a bare tool here while Android half-executed a plan — two different tool
            // executions from one model output (twin-drift audit, agent-loop P1/P2).
            let calls = planItems.compactMap { item -> ToolCall? in
                guard let dict = item as? [String: Any],
                      let tool = dict["tool"] as? String, !tool.isEmpty,
                      !isPlaceholderToolName(tool) else { return nil }
                return ToolCall(name: tool, input: dict["input"] as? String ?? "")
            }
            guard !calls.isEmpty, calls.count == planItems.count else { return nil }
            return .plan(calls)
        }
        if let tool = object["tool"] as? String, !tool.isEmpty {
            if isPlaceholderToolName(tool) { return nil }
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
