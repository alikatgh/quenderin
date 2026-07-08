import Foundation

/// A curated multi-step "recipe" — a proven skeleton a weak 4B fills in, instead of planning a whole
/// chain from scratch. This is the honest backbone of the world-class multi-step experience
/// (docs/audits/2026-07-08-world-class-multistep.md): each step carries a `toolHint`, so the live
/// checklist's cursor advances ONLY on an actually-executed tool-name match — a green check can never
/// fire on the wrong label. macOS-scoped and purely advisory: it injects guidance + re-anchors the
/// goal, but every existing guard (blocklist → consent → approval → ledger, parse/stall/fabrication)
/// fires unchanged, and a non-match degrades to exactly today's behavior. No new decision/grammar case
/// → the cross-platform parity contract is untouched (zero Kotlin/TS twin work).
public struct AgentRecipe: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let exampleGoal: String
    public let steps: [Step]

    public struct Step: Sendable, Equatable {
        public let title: String
        /// The tool that satisfies this step. Steps are tool-granular (1 step == 1 tool) so the
        /// checklist cursor maps 1:1 — the mitigation for coarse-label desync.
        public let toolHint: String
        public let guidance: String?
        public init(title: String, toolHint: String, guidance: String? = nil) {
            self.title = title; self.toolHint = toolHint; self.guidance = guidance
        }
    }

    public init(title: String, exampleGoal: String, steps: [Step]) {
        self.title = title; self.exampleGoal = exampleGoal; self.steps = steps
    }

    /// The 3 shipped recipes — deliberately the toolkit's independently-hardened, reliable chains.
    /// The fragile open→observe→tap→type GUI chain is NOT a recipe until click-verify lands, so the
    /// reliable demo is never staked on tap/type/accessibility weakness.
    public static let all: [AgentRecipe] = [
        AgentRecipe(
            title: "Morning brief",
            exampleGoal: "Make me a prep note for today",
            steps: [
                .init(title: "Read today's calendar", toolHint: "mac.calendar.today"),
                .init(title: "Write the prep note", toolHint: "mac.notes.create",
                      guidance: "Summarize today's events into a short, titled note."),
            ]),
        AgentRecipe(
            title: "Copy to draft",
            exampleGoal: "Draft an email from what I just copied",
            steps: [
                .init(title: "Read the clipboard", toolHint: "mac.clipboard.read"),
                .init(title: "Draft the email", toolHint: "mac.mail.draft",
                      guidance: "Format the input as \"to: <address> | subject: <s> | body: <b>\"."),
            ]),
        AgentRecipe(
            title: "Find and open",
            exampleGoal: "Find my report and open it",
            steps: [
                .init(title: "List the files", toolHint: "fs.list"),
                .init(title: "Reveal it in Finder", toolHint: "mac.finder.reveal"),
                .init(title: "Open it", toolHint: "mac.app.open"),
            ]),
    ]

    /// Conservative match: a per-recipe intent regex AND a requiredTools gate (every toolHint must be
    /// registered). Any miss → nil → the loop behaves exactly as today. Never fuzzy-matches the wrong
    /// recipe onto an adjacent goal.
    public static func match(goal: String, availableTools: [String]) -> AgentRecipe? {
        let g = goal.lowercased()
        let toolset = Set(availableTools)
        for (recipe, pattern) in patterns {
            guard recipe.steps.allSatisfy({ toolset.contains($0.toolHint) }) else { continue }
            if g.range(of: pattern, options: [.regularExpression]) != nil { return recipe }
        }
        return nil
    }

    private static let patterns: [(AgentRecipe, String)] = [
        // "prep note for today", "morning brief", "note … today/calendar" — but not a bare "what's on my calendar"
        (all[0], #"(prep|morning|daily)\s*(note|brief)|(note|brief).{0,20}(for )?(today|this morning)|summar.{0,20}(today|calendar).{0,20}note"#),
        // draft/compose an email FROM the clipboard / what I copied
        (all[1], #"(draft|write|compose|make).{0,25}(e?mail|message).{0,40}(clipboard|copied|i copied|just copied)|(clipboard|copied).{0,40}(e?mail|draft|message)"#),
        // find … then open/reveal a file/report/doc
        (all[2], #"(find|locate|search for).{0,40}(open|reveal|show)|open\s+(my|the)\s+.{0,20}(file|report|document|doc|pdf)"#),
    ]

    /// The numbered skeleton injected into the preamble when a recipe matches.
    public func skeleton() -> String {
        var lines = ["Do this in these steps, in order — one tool per step:"]
        for (i, s) in steps.enumerated() {
            var line = "\(i + 1). \(s.title) — use \(s.toolHint)"
            if let g = s.guidance { line += ". \(g)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// THE CROWN JEWEL re-anchor line, appended to the transcript TAIL each iteration (where a 4B
    /// attends most). Phrased "Done: …; decide the single best next action" — never "redo", so a lagging
    /// cursor holds truthfully instead of telling the model to repeat a step it already did.
    public func nextStepLine(cursor: Int) -> String {
        guard cursor < steps.count else {
            return "Recipe \"\(title)\": all \(steps.count) steps are done. Give the final answer now."
        }
        let done = cursor == 0 ? "none yet" : (cursor == 1 ? "step 1" : "steps 1–\(cursor)")
        let next = steps[cursor]
        var line = "Recipe \"\(title)\" (\(steps.count) steps). Done: \(done). "
        line += "Next is step \(cursor + 1) — \(next.title) (suggested tool: \(next.toolHint))."
        if let g = next.guidance { line += " \(g)" }
        line += " Decide the single best next action."
        return line
    }
}
