import Foundation

/// Quenderin educates rather than assumes. Our users aren't computer-native — they're ready to
/// learn — so the Agent screen explains, in plain words, how good the model they're running is at
/// being an AGENT (planning, picking tools, recovering), and what their own hardware can run.
///
/// This is the pure logic behind that panel; the view just renders what `briefing(...)` returns, so
/// the judgment (which model is good for what) is unit-tested, not buried in SwiftUI.

/// How well a model handles being an AGENT — not plain chat. Grounded in what actually ships:
/// Qwen/Llama-family models follow tool-call JSON far more reliably than a same-size Gemma (tuned
/// for multilingual chat, a weaker tool-caller — the reason the shipped default is Qwen3, not Gemma),
/// and reliability climbs with size.
public enum AgentAptitude: Int, Sendable, Comparable, CaseIterable {
    case basic = 0      // quick single actions; multi-step is unreliable at this size
    case capable = 1    // simple goals with clear instructions; may miss on complex chains
    case strong = 2     // solid multi-step tool use; occasionally needs a clearer instruction
    case excellent = 3  // plans reliably, picks the right tool, recovers on its own

    public static func < (l: AgentAptitude, r: AgentAptitude) -> Bool { l.rawValue < r.rawValue }

    public var label: String {
        switch self {
        case .basic: return "Basic"
        case .capable: return "Capable"
        case .strong: return "Strong"
        case .excellent: return "Excellent"
        }
    }

    /// One plain-English sentence a non-technical user can act on.
    public var summary: String {
        switch self {
        case .basic:     return "Best for quick, single actions — multi-step agent tasks are unreliable at this size."
        case .capable:   return "Good for simple goals with clear, direct instructions; it can miss on complex multi-step tasks."
        case .strong:    return "Handles multi-step tasks and tool use well — it just occasionally needs a clearer instruction."
        case .excellent: return "Plans reliably, picks the right tools, and recovers from its own mistakes."
        }
    }
}

/// What the Agent screen tells the user about their model + hardware. Pure data — the view renders it.
public struct AgentModelBriefing: Sendable, Equatable {
    public let modelLabel: String
    public let aptitude: AgentAptitude
    public let aptitudeDetail: String
    public let hardwareLine: String
    /// A better-for-agents model the device can run, or nil when they're already on the best fit.
    public let upgrade: Upgrade?
    public let privacyNote: String

    public struct Upgrade: Sendable, Equatable {
        public let modelLabel: String
        public let aptitude: AgentAptitude
        public let reason: String
    }
}

public enum AgentModelGuide {
    /// A model's agent aptitude, by catalog id. The load-bearing distinction: `qwen3-4b` is **strong**
    /// while same-size `gemma3-4b` is only **capable** — exactly the gap the shipped experience turns on.
    public static func aptitude(for id: String) -> AgentAptitude {
        switch id {
        // The paged 35B MoE is the strongest tool-caller in the catalog. agentRank's params
        // nudge still prefers the 14B when BOTH fit (32 GB+); on 16 GB — where the 85% budget
        // blocks the 14B — the MoE is the honest best and briefing() offers it with dedicated
        // paged-MoE copy (13 GB download, SSD-streamed), never the generic "slightly slower".
        case "qwen36-35b-a3b", "qwen3-14b":
            return .excellent
        case "gemma4-12b", "qwen25-coder-7b", "deepseek-r1-7b", "llama3-8b", "mistral-7b", "qwen3-4b":
            return .strong
        case "gemma3-4b", "phi4-mini", "llama32-3b":
            return .capable
        case "llama32-1b", "llama32-1b-q2":
            return .basic
        default:
            return .capable
        }
    }

    /// Compose the plain-English briefing for the Agent screen.
    /// - deviceNoun: "Mac" / "iPhone" — the view supplies it so this stays platform-agnostic + testable.
    public static func briefing(activeModelID: String?, totalRAMGB: Double, deviceNoun: String) -> AgentModelBriefing {
        let active = activeModelID.flatMap { ModelCatalog.entry(id: $0) }
        let activeAptitude = active.map { aptitude(for: $0.id) } ?? .capable
        let gb = Int(totalRAMGB.rounded())

        // The best model FOR AGENTS this hardware can safely load — highest aptitude, then the curated
        // tool-caller families (Qwen > Llama > Mistral/Phi > Gemma/DeepSeek), then smaller/faster. NOT
        // just the biggest that fits: a bigger Gemma is a WEAKER agent than a smaller Qwen (the whole
        // point), so "the largest model" would recommend exactly the wrong thing.
        let best = ModelCatalog.models
            .filter { MemoryFitness.check(model: $0, totalGB: totalRAMGB, freeGB: totalRAMGB).canLoad }
            .max { agentRank($0) < agentRank($1) }
        let bestAptitude = best.map { aptitude(for: $0.id) } ?? activeAptitude

        // Offer an upgrade ONLY when the device can run a genuinely more-agent-capable model than the
        // one in use — never a lateral or downgrade suggestion, and never if they're already on it.
        var upgrade: AgentModelBriefing.Upgrade?
        var hardwareLine: String
        if let active, let best, best.id != active.id, bestAptitude > activeAptitude {
            hardwareLine = "Your \(deviceNoun) has \(gb) GB of memory — enough to run a more capable agent, fully on-device."
            // The paged MoE earns different honesty: it's the strongest agent this class of
            // hardware can run, but "more memory, slightly slower" would misdescribe a 13 GB
            // download whose experts stream from the SSD. Never oversell the flagship.
            let reason: String
            if best.id == "qwen36-35b-a3b" {
                reason = "The strongest agent your \(deviceNoun) can run: a 35B mixture-of-experts model that keeps only its active parts in memory and streams the rest from your SSD. It's a 13 GB download and replies stream a bit slower — but it plans and recovers like nothing smaller. Switch anytime in Settings › Model."
            } else {
                reason = "Bigger models pick the right tool more often and recover from mistakes on their own — at the cost of more memory and slightly slower replies. Switch anytime in Settings › Model."
            }
            upgrade = .init(
                modelLabel: best.label,
                aptitude: bestAptitude,
                reason: reason
            )
        } else {
            hardwareLine = "Your \(deviceNoun) has \(gb) GB of memory — comfortably enough to run this model, fully on-device."
        }

        return AgentModelBriefing(
            modelLabel: active?.label ?? "your model",
            aptitude: activeAptitude,
            aptitudeDetail: activeAptitude.summary,
            hardwareLine: hardwareLine,
            upgrade: upgrade,
            privacyNote: "Everything runs on your \(deviceNoun) — your files and goals never leave the device."
        )
    }

    /// Rank a model AS AN AGENT: aptitude tier dominates, then the curated tool-caller families
    /// (Qwen > Llama > Mistral/Phi > Gemma/DeepSeek), then a small nudge toward the smaller/faster
    /// option within a tie. This is what makes "run a more capable agent" recommend Qwen, not the
    /// biggest model on disk.
    static func agentRank(_ m: ModelEntry) -> Double {
        let tier = Double(aptitude(for: m.id).rawValue) * 100
        let family: Double
        if m.id.hasPrefix("qwen") { family = 3 }
        else if m.id.hasPrefix("llama") { family = 2 }
        else if m.id.hasPrefix("mistral") || m.id.hasPrefix("phi") { family = 1 }
        else { family = 0 }   // gemma, deepseek — capable, but weaker/agent-quirkier tool-callers
        return tier + family - m.paramsBillions * 0.1
    }
}
