import Foundation

/// Size-class knobs for chat. Small on-device models need shorter caps and tighter style;
/// larger ones can spend more tokens. Pure — UI and ChatModel both use this.
public enum ChatTier: String, Sendable, Equatable {
    /// ~1–2B params — snappy, rambling risk high.
    case tiny
    /// ~3–5B — default phone sweet spot.
    case small
    /// ~7B+ — more room for structured answers.
    case full

    public static func of(paramsBillions: Double) -> ChatTier {
        if paramsBillions <= 2.0 { return .tiny }
        if paramsBillions <= 5.5 { return .small }
        return .full
    }

    public static func of(model: ModelEntry?) -> ChatTier {
        guard let model else { return .small }
        return of(paramsBillions: model.paramsBillions)
    }

    /// Chat decode budget — shorter for tiny models so Stop/Continue stay meaningful.
    public var maxTokens: Int {
        switch self {
        case .tiny: return 256
        case .small: return 384
        case .full: return 512
        }
    }

    /// Extra system-prompt lines appended after `ConversationContext.defaultSystemPrompt`.
    public var systemPromptSuffix: String {
        switch self {
        case .tiny:
            return " Keep every reply under ~8 short sentences unless the user asks for more detail."
        case .small:
            return " Prefer 1–3 short paragraphs or a tight bullet list."
        case .full:
            return ""
        }
    }

    /// Generation options for this tier (sampling matches `shared/sampling-profiles.json` → chat).
    public var chatOptions: GenerationOptions {
        GenerationOptions(maxTokens: maxTokens)
    }

    /// Full system prompt for this tier.
    public var systemPrompt: String {
        ConversationContext.defaultSystemPrompt + systemPromptSuffix
    }
}
