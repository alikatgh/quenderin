import Foundation

/// User-visible chat strings that live in the transcript (empty-reply notice, continue cue).
/// Kept out of the string catalog because they are also **model-facing** (continue cue is a user
/// turn) and must stay twin-identical with Android `ChatUserFacing`. Localize by locale code, not
/// `String(localized:)`, so pure unit tests and CoreVerify stay deterministic.
public enum ChatUserFacing: Sendable {
    /// Canonical English — tests pin this substring; golden/CI locale is en.
    public static let emptyReplyEnglish =
        "The model returned an empty reply. Try rephrasing, or pick a larger model in the Model library."

    public static let continueCueEnglish =
        "Continue from where you left off. Do not repeat what you already wrote."

    /// Honest zero-token notice for the assistant bubble (not a silent empty bubble).
    public static func emptyReply(locale: Locale = .current) -> String {
        switch languageCode(locale) {
        case "ru":
            return "Модель вернула пустой ответ. Переформулируйте запрос или выберите модель побольше в библиотеке."
        case "ko":
            return "모델이 빈 답변을 반환했습니다. 다시 표현해 보거나 모델 라이브러리에서 더 큰 모델을 고르세요."
        case "ja":
            return "モデルが空の返信を返しました。言い換えるか、モデルライブラリで大きなモデルを選んでください。"
        case "zh":
            return "模型返回了空回复。请换个说法，或在模型库中选择更大的模型。"
        default:
            return emptyReplyEnglish
        }
    }

    /// Sent as a user turn after a token-cap stop so the model continues mid-thought.
    /// Locale-matched so a Russian chat doesn't get yanked into English by the cue.
    public static func continueCue(locale: Locale = .current) -> String {
        switch languageCode(locale) {
        case "ru":
            return "Продолжи с того места, где остановился. Не повторяй уже написанное."
        case "ko":
            return "멈춘 부분부터 이어서 작성하세요. 이미 쓴 내용은 반복하지 마세요."
        case "ja":
            return "止まったところから続けてください。すでに書いた内容は繰り返さないでください。"
        case "zh":
            return "从中断处继续。不要重复已经写过的内容。"
        default:
            return continueCueEnglish
        }
    }

    private static func languageCode(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? "en"
    }
}
