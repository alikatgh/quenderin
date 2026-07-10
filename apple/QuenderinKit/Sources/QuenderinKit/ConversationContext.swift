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
        "Be concise and accurate. You have no internet access. " +
        // Chat has no tools. Never refuse at length ("I cannot fulfill…") — educate in 1–2
        // short sentences and point to the Agent (sparkle in the sidebar). The app also shows
        // a one-tap button; the model must not invent that it already acted.
        "You cannot open apps, control the browser, send email, or change files from chat. " +
        "If the user asks for that, reply briefly: chat is for conversation; the Agent " +
        "(sparkle icon) can do it with their permission. Do not write long apologies or " +
        "repeat the same refusal. Never claim you performed an action."

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
    ///
    /// `contextTokensOverride` is the loaded engine's ACTUAL `n_ctx` (often 512–2048 on phones,
    /// sized from the device's memory at load) — when supplied it replaces the configured
    /// `contextTokens`, so the trim matches the real native window instead of a hardcoded 4096
    /// that silently overflows it (Q-167; this override existed only on Android until the
    /// twin-drift audit). Nil (mock/scripted engines and the pure prompt-building tests) falls
    /// back to `contextTokens`.
    public func windowedHistory(_ history: [ChatMessage], contextTokensOverride: Int? = nil) -> [ChatMessage] {
        let budget = historyBudget(effectiveContextTokens: contextTokensOverride ?? contextTokens)
        var kept: [ChatMessage] = []
        var used = 0
        for message in history.reversed() {                 // newest → oldest
            let cost = Self.estimateTokens(Self.line(for: message))
            if kept.isEmpty || used + cost <= budget {
                kept.append(message)
                used += cost
            } else {
                break
            }
        }
        kept.reverse()                                       // restore chronological order
        return kept
    }

    /// Tokens available for history after the system prompt and the trailing primer, given the
    /// effective context window (the loaded engine's real `n_ctx` when known — see `windowedHistory`).
    private func historyBudget(effectiveContextTokens: Int) -> Int {
        let overhead = Self.estimateTokens(systemPrompt) + Self.estimateTokens(Self.assistantPrimer)
        return max(0, effectiveContextTokens - reservedForResponse - overhead)
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
