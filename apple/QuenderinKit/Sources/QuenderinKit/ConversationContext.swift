import Foundation

/// Assembles the prompt sent to the engine from the running conversation: a system
/// prompt plus as much recent history as fits a token budget. This is what gives chat
/// **memory** — without it the model sees only the latest line and forgets every prior
/// turn. Pure and deterministic, so it unit-tests with no engine. Twin of Kotlin
/// `ConversationContext`; mirrors the desktop's system-prompt + context-budget approach
/// (`presets.ts`).
public struct ConversationContext: Sendable, Equatable {
    /// Persona / standing instructions, always kept ahead of the history.
    public var systemPrompt: String
    /// Approximate size of the model's context window, in tokens.
    public var contextTokens: Int
    /// Tokens to leave free for the reply, so prompt + response fit the window.
    public var reservedForResponse: Int

    public static let defaultSystemPrompt =
        "You are Quenderin, a helpful assistant running entirely on-device and offline. " +
        "Be concise and accurate. You have no internet access."

    public init(
        systemPrompt: String = ConversationContext.defaultSystemPrompt,
        contextTokens: Int = 4096,
        reservedForResponse: Int = 512
    ) {
        self.systemPrompt = systemPrompt
        self.contextTokens = contextTokens
        self.reservedForResponse = reservedForResponse
    }

    /// Build the instruct prompt, keeping the system prompt plus the most recent turns that
    /// fit the budget (oldest dropped first; the latest turn is always kept, even if it alone
    /// exceeds the budget — we never silently drop the message the user just sent).
    public func build(history: [ChatMessage]) -> String {
        let kept = windowedHistory(history)
        var prompt = systemPrompt.isEmpty ? "" : systemPrompt + "\n\n"
        prompt += kept.map(Self.line(for:)).joined(separator: "\n")
        if !kept.isEmpty { prompt += "\n" }
        prompt += Self.assistantPrimer
        return prompt
    }

    /// The most recent turns that fit the context budget — the windowing half of `build`, without
    /// the flat formatting — for engines that format the conversation with the model's OWN chat
    /// template instead. Twin of Kotlin `ConversationContext.windowedHistory`.
    public func windowedHistory(_ history: [ChatMessage]) -> [ChatMessage] {
        var kept: [ChatMessage] = []
        var used = 0
        for message in history.reversed() {                 // newest → oldest
            let cost = Self.estimateTokens(Self.line(for: message))
            if kept.isEmpty || used + cost <= historyBudget {
                kept.append(message)
                used += cost
            } else {
                break
            }
        }
        kept.reverse()                                       // restore chronological order
        return kept
    }

    /// Tokens available for history after the system prompt and the trailing primer.
    var historyBudget: Int {
        let overhead = Self.estimateTokens(systemPrompt) + Self.estimateTokens(Self.assistantPrimer)
        return max(0, contextTokens - reservedForResponse - overhead)
    }

    private static let assistantPrimer = "Assistant:"

    private static func line(for message: ChatMessage) -> String {
        let speaker = message.role == .user ? "User" : "Assistant"
        return "\(speaker): \(message.text)"
    }

    /// Rough token estimate (~4 chars/token) — an honest stand-in until the real
    /// llama.cpp tokenizer is wired; accurate enough for context-window budgeting.
    static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }
}
