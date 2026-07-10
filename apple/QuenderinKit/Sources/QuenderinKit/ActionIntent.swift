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
    static let patterns: [String] = [
        #"\b(open|launch|start|quit|close)\b.*\b(browser|safari|chrome|firefox|mail|finder|app|application)\b"#,
        #"\b(write|send|compose|draft)\b.*\b(e-?mail|message)\b"#,
        #"\b(organize|organise|clean|sort|tidy)\b.*\b(files?|folders?|desktop|downloads|documents)\b"#,
        #"\b(move|rename|trash|copy)\b.*\b(files?|folders?)\b"#,
        #"\brun\b.*\bshortcut"#,
        #"\b(create|make)\b.*\b(folder|directory)\b"#,
    ]

    /// True when the text reads as an operate-the-computer request rather than a question.
    public static func looksLikeComputerTask(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    /// Fixed educational reply when chat short-circuits a computer task — no model call, no
    /// "I cannot fulfill that request" wall. The UI always pairs this with a real button.
    public static let guidedAssistantReply =
        "Chat is for questions and writing help — it can’t open apps, control the browser, or send mail on your Mac.\n\n" +
        "**The Agent can.** Tap the sparkle icon in the sidebar, or use the button below. " +
        "It will take your request and ask before changing anything."

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
    public static func displayAssistantText(_ text: String) -> String {
        looksLikeAgentRedirectProse(text) ? guidedAssistantReply : text
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
