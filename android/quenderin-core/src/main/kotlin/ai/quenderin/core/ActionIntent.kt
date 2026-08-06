package ai.quenderin.core

/**
 * Deterministic "this chat message is really a COMPUTER TASK" detector — twin of Swift
 * `ActionIntent` (identical pattern strings; both platforms run the same fixtures in their
 * checks). Detection in code lets the chat UI offer a one-tap "Open in Agent" handoff
 * instead of relying on the model to produce redirect prose the user must interpret.
 *
 * Conservative by design (precision over recall): a missed detection costs nothing — the chat
 * reply still explains — while a false positive nags.
 */
object ActionIntent {
    /**
     * Regexes over the lowercased message. IDENTICAL strings in the Swift twin.
     * English uses `\b`; Russian patterns omit `\b` (Unicode word boundaries are unreliable
     * for Cyrillic in both Swift and Kotlin regex engines).
     */
    private val patterns: List<Regex> = listOf(
        """\b(open|launch|start|quit|close)\b.*\b(browser|safari|chrome|firefox|mail|finder|app|application)\b""",
        """\b(write|send|compose|draft)\b.*\b(e-?mail|message)\b""",
        """\b(organize|organise|clean|sort|tidy)\b.*\b(files?|folders?|desktop|downloads|documents)\b""",
        """\b(move|rename|trash|copy)\b.*\b(files?|folders?)\b""",
        """\brun\b.*\bshortcut""",
        """\b(create|make)\b.*\b(folder|directory)\b""",
        // Russian-first (conservative — verb + object, not single-word chat questions).
        """открой.*(браузер|chrome|safari|firefox|почт|приложен|mail)""",
        """(запусти|закрой).*(браузер|chrome|safari|приложен|mail)""",
        """(напиши|отправь|составь).*(письм|email|e-mail|сообщен)""",
        """(организуй|убери|разбери|почисти).*(файл|папк|загрузк|документ|рабоч)""",
        """(переименуй|перемести|удали|скопируй).*(файл|папк)""",
        """создай.*папк""",
    ).map { Regex(it) }

    /** True when the text reads as an operate-the-computer request rather than a question. */
    fun looksLikeComputerTask(text: String): Boolean {
        val lowered = text.lowercase()
        return patterns.any { it.containsMatchIn(lowered) }
    }

    /**
     * Fixed educational reply when chat short-circuits a computer task — no model call, no
     * "I cannot fulfill that request" wall. The UI always pairs this with a real button.
     * Mobile wording (phone), twin intent of iOS `guidedAssistantReply` (Mac).
     * Canonical English — tests / CoreVerify pin this string.
     */
    const val GUIDED_ASSISTANT_REPLY =
        "Chat is for questions and writing help — it can’t open apps, control the browser, or send mail for you.\n\n" +
            "**The Agent can.** Tap **Agent** in the tab bar, or use the button below. " +
            "It will take your request and ask before changing anything."

    /** Locale-aware guided reply for the transcript (ru/ko/ja/zh); default English. */
    fun guidedAssistantReply(languageCode: String? = null): String {
        return when (languageCode?.lowercase()?.substringBefore('-')) {
            "ru" ->
                "Чат — для вопросов и помощи с текстом. Он не открывает приложения, не управляет браузером и не шлёт почту.\n\n" +
                    "**Это может Агент.** Нажмите **Агент** внизу или кнопку ниже. " +
                    "Он возьмёт ваш запрос и спросит перед любыми изменениями."
            "ko" ->
                "채팅은 질문과 글쓰기 도움용입니다. 앱을 열거나 브라우저를 제어하거나 메일을 보내지 않습니다.\n\n" +
                    "**에이전트는 할 수 있습니다.** 하단 **에이전트** 탭 또는 아래 버튼을 누르세요. " +
                    "요청을 받아 변경 전에 확인합니다."
            "ja" ->
                "チャットは質問と文章の手伝い用です。アプリ起動・ブラウザ操作・メール送信はできません。\n\n" +
                    "**エージェントなら可能です。** 下の **エージェント** タブか下のボタンを押してください。" +
                    "変更の前に確認します。"
            "zh" ->
                "聊天用于提问和写作帮助——它不会打开应用、控制浏览器或发邮件。\n\n" +
                    "**智能体可以。** 点底部 **智能体** 或下方按钮。" +
                    "它会接手请求，并在做任何更改前征求同意。"
            else -> GUIDED_ASSISTANT_REPLY
        }
    }

    /** In-transcript / composer link label — modest, not a billboard. */
    const val HANDOFF_BUTTON_TITLE = "Open in Agent"

    /**
     * True when an assistant bubble is the old model-generated "use the Agent tab" wall — so the
     * UI can show [GUIDED_ASSISTANT_REPLY] instead of replaying "I cannot fulfill that request".
     */
    fun looksLikeAgentRedirectProse(text: String): Boolean {
        val t = text.lowercase()
        if (t.contains("i cannot fulfill")) return true
        if (t.contains("cannot open a browser") || t.contains("can't open a browser")) return true
        if (t.contains("agent tab") &&
            (t.contains("cannot") || t.contains("can't") ||
                t.contains("do not have the ability") || t.contains("don't have the ability") ||
                t.contains("designed to operate offline"))
        ) {
            return true
        }
        if (t.contains("sparkle") &&
            (t.contains("cannot") || t.contains("can't") || t.contains("please use the agent"))
        ) {
            return true
        }
        return false
    }

    /** Text to show for an assistant bubble: rewrite dead-end agent redirects to the guided copy. */
    fun displayAssistantText(text: String, languageCode: String? = null): String =
        if (looksLikeAgentRedirectProse(text)) guidedAssistantReply(languageCode) else text
}
