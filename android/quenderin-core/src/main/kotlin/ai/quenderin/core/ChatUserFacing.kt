package ai.quenderin.core

/**
 * User-visible chat strings that land in the transcript (empty-reply notice, continue cue).
 * Twin of iOS `ChatUserFacing` — keep wording and locale packs in sync.
 *
 * Localized by ISO language code (not Android string resources) so pure CoreVerify stays free of
 * Context/Resources and so the continue cue (a user turn) matches the UI language.
 */
object ChatUserFacing {
    /** Canonical English — CoreVerify / tests pin the "empty reply" substring. */
    const val EMPTY_REPLY_ENGLISH =
        "The model returned an empty reply. Try rephrasing, or pick a larger model in the Model library."

    const val CONTINUE_CUE_ENGLISH =
        "Continue from where you left off. Do not repeat what you already wrote."

    /** Honest zero-token notice for the assistant bubble. */
    fun emptyReply(languageCode: String? = null): String {
        return when (normalize(languageCode)) {
            "ru" ->
                "Модель вернула пустой ответ. Переформулируйте запрос или выберите модель побольше в библиотеке."
            "ko" ->
                "모델이 빈 답변을 반환했습니다. 다시 표현해 보거나 모델 라이브러리에서 더 큰 모델을 고르세요."
            "ja" ->
                "モデルが空の返信を返しました。言い換えるか、モデルライブラリで大きなモデルを選んでください。"
            "zh" ->
                "模型返回了空回复。请换个说法，或在模型库中选择更大的模型。"
            else -> EMPTY_REPLY_ENGLISH
        }
    }

    /**
     * Sent as a user turn after a token-cap stop. Locale-matched so a Russian chat doesn't get
     * yanked into English by the continue cue.
     */
    fun continueCue(languageCode: String? = null): String {
        return when (normalize(languageCode)) {
            "ru" -> "Продолжи с того места, где остановился. Не повторяй уже написанное."
            "ko" -> "멈춘 부분부터 이어서 작성하세요. 이미 쓴 내용은 반복하지 마세요."
            "ja" -> "止まったところから続けてください。すでに書いた内容は繰り返さないでください。"
            "zh" -> "从中断处继续。不要重复已经写过的内容。"
            else -> CONTINUE_CUE_ENGLISH
        }
    }

    private fun normalize(code: String?): String? =
        code?.lowercase()?.substringBefore('-')?.takeIf { it.isNotBlank() }
}
