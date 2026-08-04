package ai.quenderin.core

/**
 * First-message chips for an empty chat. Tuned for **1–4B on-device** models: short prompts,
 * concrete tasks. Twin of iOS `ChatStarters` — keep titles/prompts/ids in sync when editing either.
 */
data class ChatStarter(
    val id: String,
    /** Short chip label. */
    val title: String,
    /** Full prompt inserted/sent when the chip is tapped. */
    val prompt: String,
)

object ChatStarters {
    /** English source pack — ids/order are the golden-chat contract (keep in sync with iOS). */
    val offlineChat: List<ChatStarter> = listOf(
        ChatStarter(
            id = "summarize",
            title = "Summarize",
            prompt = "Summarize the following in 3 short bullet points. If I haven't pasted anything yet, ask me what to summarize:\n\n",
        ),
        ChatStarter(
            id = "rewrite",
            title = "Rewrite clearly",
            prompt = "Rewrite this so it's clearer and more concise, without changing the meaning:\n\n",
        ),
        ChatStarter(
            id = "translate",
            title = "Translate",
            prompt = "Translate the following into Spanish. Keep names and numbers unchanged:\n\n",
        ),
        ChatStarter(
            id = "brainstorm",
            title = "Brainstorm",
            prompt = "Give me 5 practical dinner ideas that use eggs and rice. One line each.",
        ),
        ChatStarter(
            id = "explain",
            title = "Explain simply",
            prompt = "Explain jet lag like I'm 12 years old — short paragraphs, no jargon.",
        ),
        ChatStarter(
            id = "math",
            title = "Quick math",
            prompt = "What is 17% of 240? Show the arithmetic in one line.",
        ),
        ChatStarter(
            id = "email",
            title = "Draft email",
            prompt = "Draft a short, polite email declining a meeting because of a schedule conflict. Warm but firm, under 80 words.",
        ),
        ChatStarter(
            id = "checklist",
            title = "Packing list",
            prompt = "Make a packing checklist for a 3-day weekend city trip. Group by: bag, clothes, tech, documents.",
        ),
    )

    /**
     * Localized first-run chips for [languageCode] (ISO 639-1, e.g. "ru", "ko", "ja", "zh").
     * Unknown codes fall back to English. Twin of iOS `ChatStarters.offlineChat(locale:)`.
     */
    fun offlineChat(languageCode: String?): List<ChatStarter> {
        val code = languageCode?.lowercase()?.substringBefore('-') ?: return offlineChat
        val table = localeTables[code] ?: return offlineChat
        return offlineChat.map { starter ->
            val pair = table[starter.id] ?: return@map starter
            ChatStarter(id = starter.id, title = pair.first, prompt = pair.second)
        }
    }

    private val localeTables: Map<String, Map<String, Pair<String, String>>> = mapOf(
        "ru" to mapOf(
            "summarize" to (
                "Кратко" to
                    "Суммируй следующее в 3 коротких пункта. Если я ещё ничего не вставил, спроси, что суммировать:\n\n"
                ),
            "rewrite" to (
                "Переписать яснее" to
                    "Перепиши это яснее и короче, не меняя смысла:\n\n"
                ),
            "translate" to (
                "Перевести" to
                    "Переведи следующее на испанский. Имена и числа не меняй:\n\n"
                ),
            "brainstorm" to (
                "Идеи" to
                    "Дай 5 практичных идей ужина из яиц и риса. По одной строке на каждую."
                ),
            "explain" to (
                "Объясни просто" to
                    "Объясни джетлаг, как будто мне 12 лет — короткие абзацы, без жаргона."
                ),
            "math" to (
                "Быстрый счёт" to
                    "Сколько 17% от 240? Покажи арифметику в одну строку."
                ),
            "email" to (
                "Черновик письма" to
                    "Напиши короткое вежливое письмо с отказом от встречи из‑за конфликта в расписании. Тёплое, но твёрдое, до 80 слов."
                ),
            "checklist" to (
                "Список в дорогу" to
                    "Составь чек‑лист сборов на 3‑дневную поездку в город на выходные. Группы: сумка, одежда, техника, документы."
                ),
        ),
        "ko" to mapOf(
            "summarize" to (
                "요약" to
                    "다음 내용을 짧은 글머리 3개로 요약해 주세요. 아직 붙여넣지 않았다면 무엇을 요약할지 물어보세요:\n\n"
                ),
            "rewrite" to (
                "더 명확히 다시 쓰기" to
                    "의미를 바꾸지 않고 더 명확하고 간결하게 다시 써 주세요:\n\n"
                ),
            "translate" to (
                "번역" to
                    "다음을 스페인어로 번역하세요. 이름과 숫자는 그대로 두세요:\n\n"
                ),
            "brainstorm" to (
                "아이디어" to
                    "달걀과 쌀로 만들 수 있는 실용적인 저녁 메뉴 5가지를 한 줄씩 알려 주세요."
                ),
            "explain" to (
                "쉽게 설명" to
                    "시차를 12살에게 설명하듯 짧게, 전문 용어 없이 설명해 주세요."
                ),
            "math" to (
                "빠른 계산" to
                    "240의 17%는? 계산을 한 줄로 보여 주세요."
                ),
            "email" to (
                "이메일 초안" to
                    "일정 충돌로 미팅을 정중히 거절하는 짧은 이메일을 작성해 주세요. 따뜻하지만 단호하게, 80단어 이내."
                ),
            "checklist" to (
                "짐 목록" to
                    "3일 주말 도시 여행 짐 체크리스트를 만들어 주세요. 가방, 옷, 기기, 서류로 나누세요."
                ),
        ),
        "ja" to mapOf(
            "summarize" to (
                "要約" to
                    "次を短い箇条書き3点で要約してください。まだ貼り付けていない場合は、何を要約するか聞いてください:\n\n"
                ),
            "rewrite" to (
                "わかりやすく書き直し" to
                    "意味を変えずに、より明確で簡潔に書き直してください:\n\n"
                ),
            "translate" to (
                "翻訳" to
                    "次をスペイン語に翻訳してください。名前と数字はそのまま:\n\n"
                ),
            "brainstorm" to (
                "アイデア" to
                    "卵と米で作れる実用的な夕食アイデアを5つ、1行ずつください。"
                ),
            "explain" to (
                "やさしく説明" to
                    "時差ぼけを12歳にもわかるように、短い段落で専門用語なしで説明してください。"
                ),
            "math" to (
                "さっと計算" to
                    "240の17%は？計算を1行で示してください。"
                ),
            "email" to (
                "メール下書き" to
                    "予定の都合で会議を断る短い丁寧なメールを書いてください。温かくもはっきりと、80語以内。"
                ),
            "checklist" to (
                "持ち物リスト" to
                    "3日間の週末シティ旅行の荷物チェックリストを作ってください。バッグ・服・テック・書類に分けて。"
                ),
        ),
        "zh" to mapOf(
            "summarize" to (
                "摘要" to
                    "用 3 条简短要点总结以下内容。如果我还没粘贴内容，请问我要总结什么：\n\n"
                ),
            "rewrite" to (
                "改写清楚" to
                    "在不改变意思的前提下，把下面写得更清楚、更简洁：\n\n"
                ),
            "translate" to (
                "翻译" to
                    "将下列内容翻译成西班牙语。姓名和数字保持不变：\n\n"
                ),
            "brainstorm" to (
                "头脑风暴" to
                    "给我 5 个用鸡蛋和大米做的实用晚餐点子，每条一行。"
                ),
            "explain" to (
                "简单解释" to
                    "用 12 岁孩子能懂的方式解释时差——短段落，不要术语。"
                ),
            "math" to (
                "快速计算" to
                    "240 的 17% 是多少？用一行写出算式。"
                ),
            "email" to (
                "邮件草稿" to
                    "起草一封简短礼貌的邮件，因时间冲突婉拒会议。语气温暖但坚定，不超过 80 词。"
                ),
            "checklist" to (
                "打包清单" to
                    "做一份 3 天周末城市旅行的打包清单。按：包、衣物、电子设备、证件 分组。"
                ),
        ),
    )
}
