import Foundation
#if canImport(Combine)
import Combine
#endif

/// Deterministic "this chat message is really a COMPUTER TASK" detector — the code-level fix for
/// a failure the model cannot be trusted to handle: a user types "open browser and write email
/// to …" into CHAT, and the best a system prompt can produce is redirect PROSE the user must
/// read, interpret, and act on ("this shit is not working at all" — live report). Detection in
/// code means the UI can offer a one-tap "Go to Agent and run this" instead of a dead-end refusal.
///
/// Conservative by design (precision over recall): a missed detection costs nothing — the chat
/// reply still explains — while a false positive nags. Pattern list kept in lockstep with the
/// Kotlin twin (`ai.quenderin.core.ActionIntent`); both platforms run the same fixtures.
public enum ActionIntent {
    /// Regexes over the lowercased message. IDENTICAL strings in the Kotlin twin.
    /// English uses `\b`; Russian patterns omit `\b` (Cyrillic word boundaries are unreliable).
    static let patterns: [String] = [
        #"\b(open|launch|start|quit|close)\b.*\b(browser|safari|chrome|firefox|mail|finder|app|application)\b"#,
        #"\b(write|send|compose|draft)\b.*\b(e-?mail|message)\b"#,
        #"\b(organize|organise|clean|sort|tidy)\b.*\b(files?|folders?|desktop|downloads|documents)\b"#,
        #"\b(move|rename|trash|copy)\b.*\b(files?|folders?)\b"#,
        #"\brun\b.*\bshortcut"#,
        #"\b(create|make)\b.*\b(folder|directory)\b"#,
        // Russian-first (conservative — verb + object, not single-word chat questions).
        #"открой.*(браузер|chrome|safari|firefox|почт|приложен|mail)"#,
        #"(запусти|закрой).*(браузер|chrome|safari|приложен|mail)"#,
        #"(напиши|отправь|составь).*(письм|email|e-mail|сообщен)"#,
        #"(организуй|убери|разбери|почисти).*(файл|папк|загрузк|документ|рабоч)"#,
        #"(переименуй|перемести|удали|скопируй).*(файл|папк)"#,
        #"создай.*папк"#,
    ]

    /// True when the text reads as an operate-the-computer request rather than a question.
    public static func looksLikeComputerTask(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    /// Fixed educational reply when chat short-circuits a computer task — no model call, no
    /// "I cannot fulfill that request" wall. The UI always pairs this with a real button.
    /// Canonical English — unit tests pin this string.
    public static let guidedAssistantReply =
        "Chat is for questions and writing help — it can’t open apps, control the browser, or send mail on your Mac.\n\n" +
        "**The Agent can.** Tap the sparkle icon in the sidebar, or use the button below. " +
        "It will take your request and ask before changing anything."

    /// Locale-aware guided reply for the transcript (ru/ko/ja/zh); default English.
    /// Named separately from the English constant so call sites stay unambiguous.
    public static func localizedGuidedReply(locale: Locale = .current) -> String {
        switch locale.language.languageCode?.identifier {
        case "ru":
            return "Чат — для вопросов и помощи с текстом. Он не открывает приложения, не управляет браузером и не шлёт почту.\n\n" +
                "**Это может Агент.** Нажмите иконку искры в боковой панели или кнопку ниже. " +
                "Он возьмёт ваш запрос и спросит перед любыми изменениями."
        case "ko":
            return "채팅은 질문과 글쓰기 도움용입니다. 앱을 열거나 브라우저를 제어하거나 메일을 보내지 않습니다.\n\n" +
                "**에이전트는 할 수 있습니다.** 사이드바의 반짝이 아이콘 또는 아래 버튼을 누르세요. " +
                "요청을 받아 변경 전에 확인합니다."
        case "ja":
            return "チャットは質問と文章の手伝い用です。アプリ起動・ブラウザ操作・メール送信はできません。\n\n" +
                "**エージェントなら可能です。** サイドバーのスパークルか下のボタンを押してください。" +
                "変更の前に確認します。"
        case "zh":
            return "聊天用于提问和写作帮助——它不会打开应用、控制浏览器或发邮件。\n\n" +
                "**智能体可以。** 点侧栏火花图标或下方按钮。" +
                "它会接手请求，并在做任何更改前征求同意。"
        default:
            return guidedAssistantReply
        }
    }

    /// In-transcript / composer link label — modest, not a billboard.
    public static let handoffButtonTitle = "Open in Agent"

    /// True when an assistant bubble is the old model-generated "use the Agent tab" wall — so the
    /// UI can show `guidedAssistantReply` instead of replaying "I cannot fulfill that request".
    public static func looksLikeAgentRedirectProse(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("i cannot fulfill") { return true }
        if t.contains("cannot open a browser") || t.contains("can't open a browser") { return true }
        if t.contains("agent tab") && (t.contains("cannot") || t.contains("can't")
            || t.contains("do not have the ability") || t.contains("don't have the ability")
            || t.contains("designed to operate offline")) { return true }
        if t.contains("sparkle") && (t.contains("cannot") || t.contains("can't")
            || t.contains("please use the agent")) { return true }
        return false
    }

    /// Text to show for an assistant bubble: rewrite dead-end agent redirects to the guided copy.
    public static func displayAssistantText(_ text: String, locale: Locale = .current) -> String {
        looksLikeAgentRedirectProse(text) ? localizedGuidedReply(locale: locale) : text
    }
}

/// The chat→agent baton: chat posts a goal here; the shell (Mac rail / iOS tabs) switches to the
/// Agent surface, and `AgentView` consumes and RUNS it. A published property rather than a
/// callback chain so the three parties stay decoupled.
@MainActor
public final class AgentHandoff: ObservableObject {
    public static let shared = AgentHandoff()
    /// A goal waiting to run on the Agent surface. Set by chat's "Run with the Agent" button;
    /// cleared by AgentView the moment it starts the run.
    @Published public var pending: String?

    public init() {}

    public func send(_ goal: String) { pending = goal }
}
