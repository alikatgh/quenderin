import Foundation

/// On-device pace for local chat and tools.
///
/// A missing tool decision runs nothing. Calculator, units, and dates start on
/// and can be turned off. Reply text is checked here, not by a second model and
/// not by a network call. Photos and speech stay unloaded until those screens open.
/// DeepSeek and the remote computer path are separate and are not handled here.
public enum LocalPace {
    public static let builtinIDs: Set<String> = ["calculator", "units", "date"]
    public static let held = "Nothing ran."
    public static let withheld = "Refused: the result mentions a blocked action. Nothing was shown."
    public static let practiceLine =
        "Calculator, units, and dates answer practice questions on this device. This does not test the model."
    public static let staysHere = "Local chats, checks, and tools stay on this device. No account."
    public static let roleCheck = "On this device, before you see the reply"
    public static let rolePerception = "Separate, and not loaded with chat"
    public static let heldReply =
        "Held on this device. This reply mentions a sensitive action, so it is not shown. Nothing was sent."

    private static func key(_ name: String) -> String { "quenderin.builtinTool.\(name)" }

    public static func isOn(_ name: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(name)) == nil || defaults.bool(forKey: key(name))
    }

    public static func setOn(_ name: String, _ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key(name))
    }

    /// A blank name, or a builtin tool the person turned off, does not run.
    public static func admits(_ name: String, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if builtinIDs.contains(trimmed), !isOn(trimmed, defaults: defaults) { return false }
        return true
    }

    /// Replace a blocked tool result before it is shown or fed back.
    public static func present(_ text: String) -> String {
        SafetyBlocklist.isBlocked(text) ? withheld : text
    }

    public static func practiceOk() async -> Bool {
        (try? await CalculatorTool().run("2+2")) == "4"
            && (try? await UnitConverterTool().run("1 km to m")) == "1 km = 1000 m"
            && (try? await DateCalcTool().run("2026-06-08 plus 90 days")) == "2026-09-06"
    }

    public static func offered(_ tools: [AgentTool], defaults: UserDefaults = .standard) -> [AgentTool] {
        tools.filter { admits($0.name, defaults: defaults) }
    }

    /// Status under the model name. Empty until the person has typed, so first open stays one line.
    public static func statusLine(firstUserText: String?, badge: String) -> String {
        let trimmed = firstUserText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return badge }
        return "\(ConversationSummary.title(fromFirstUserMessage: trimmed)) · \(badge)"
    }
}
