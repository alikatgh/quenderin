import Foundation
#if canImport(Combine)
import Combine
#endif

/// Deterministic "this chat message is really a COMPUTER TASK" detector — the code-level fix for
/// a failure the model cannot be trusted to handle: a user types "open browser and write email
/// to …" into CHAT, and the best a system prompt can produce is redirect PROSE the user must
/// read, interpret, and act on ("this shit is not working at all" — live report). Detection in
/// code means the UI can offer a one-tap "Run with the Agent" instead.
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
