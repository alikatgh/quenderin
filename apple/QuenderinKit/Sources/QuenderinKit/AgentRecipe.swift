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
    /// True when this recipe was AUTHORED BY THE MODEL for this goal (dynamic planning), not one of the
    /// curated `.all`. A dynamic plan's step count is a model GUESS, so it earns weaker treatment than a
    /// human-vouched recipe: plain step cap (no +2 slack), an abandonable re-anchor that self-demotes to
    /// the neutral goal restatement when the model diverges, no "done → answer" assertion, and no guard-#6
    /// nag on a legitimate answer. The honest cursor itself is IDENTICAL — a tick still fires only on a
    /// real executed-tool match. (docs/audits/2026-07-08-dynamic-planning.md)
    public let isDynamic: Bool

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

    public init(title: String, exampleGoal: String, steps: [Step], isDynamic: Bool = false) {
        self.title = title; self.exampleGoal = exampleGoal; self.steps = steps; self.isDynamic = isDynamic
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
        // Live-caught: free-form "put birthday on calendar today" failed when a 1B copied prompt
        // placeholders instead of mac.calendar.add. Skeleton teaches the exact input shape.
        AgentRecipe(
            title: "Add calendar event",
            exampleGoal: "Put my daughter's birthday on the calendar today",
            steps: [
                .init(title: "Add the event", toolHint: "mac.calendar.add",
                      guidance: "Input format: \"Title | today HH:MM | minutes\" (or YYYY-MM-DD HH:MM). Example: \"Daughter birthday | today 09:00 | 60\"."),
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

    /// Build a DYNAMIC recipe from a model-authored plan (dynamic planning). Keeps only calls to
    /// REGISTERED tools — spelled exactly as `execute(name:)` looks them up, so the cursor's
    /// `toolHint == executedName` match can actually fire — collapses consecutive duplicate tools
    /// (1 step == 1 tool, the desync mitigation), clamps a runaway plan to `maxSteps`, and rejects a
    /// plan of fewer than 2 real steps (nothing multi-step to draw → the caller falls back to today's
    /// reactive loop). Every step's title/guidance is synthesized from the tool's OWN `purpose` — the
    /// model supplies only tool NAMES (a `ToolCall` has no label field), so a green tick can never carry
    /// a model-authored claim that desyncs from what ran. Pure + deterministic.
    public static func parsePlan(_ calls: [ToolCall], tools: [AgentTool], maxSteps: Int) -> AgentRecipe? {
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var steps: [Step] = []
        for call in calls {
            guard let tool = byName[call.name] else { continue }        // drop hallucinated tool names
            if steps.last?.toolHint == call.name { continue }           // collapse consecutive duplicates
            steps.append(Step(title: titleFromPurpose(tool.purpose, name: tool.name),
                              toolHint: tool.name, guidance: tool.purpose))
            if steps.count >= max(1, maxSteps) { break }                // clamp a runaway plan
        }
        guard steps.count >= 2 else { return nil }
        return AgentRecipe(title: "Plan", exampleGoal: "", steps: steps, isDynamic: true)
    }

    /// A short, human step title distilled from a tool's `purpose` (its first sentence/clause), capped so
    /// the checklist row stays tidy. Deterministic — no model text enters the label. Falls back to the
    /// tool name for an empty/odd purpose.
    static func titleFromPurpose(_ purpose: String, name: String) -> String {
        let firstClause = purpose.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? purpose
        let trimmed = firstClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? name : trimmed
        return title.count > 60
            ? String(title.prefix(57)).trimmingCharacters(in: .whitespaces) + "…"
            : title
    }

    private static let patterns: [(AgentRecipe, String)] = [
        // "prep note for today", "morning brief", "note … today/calendar" — but not a bare "what's on my calendar"
        (all[0], #"(prep|morning|daily)\s*(note|brief)|(note|brief).{0,20}(for )?(today|this morning)|summar.{0,20}(today|calendar).{0,20}note"#),
        // draft/compose an email FROM the clipboard / what I copied
        (all[1], #"(draft|write|compose|make).{0,25}(e?mail|message).{0,40}(clipboard|copied|i copied|just copied)|(clipboard|copied).{0,40}(e?mail|draft|message)"#),
        // find … then open/reveal a file/report/doc
        (all[2], #"(find|locate|search for).{0,40}(open|reveal|show)|open\s+(my|the)\s+.{0,20}(file|report|document|doc|pdf)"#),
        // add / put / schedule an event or birthday on the calendar (not bare "what's on calendar")
        (all[3], #"(add|put|create|schedule|set).{0,40}(calendar|event|appointment|birthday|reminder).{0,30}(today|tomorrow|calendar)?|(birthday|anniversary).{0,40}(calendar|today)|(calendar).{0,40}(add|put|create|birthday|event)"#),
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
            // H4: a curated recipe's chain is human-vouched, so "all done → answer" is safe. A DYNAMIC
            // plan's length is a model GUESS, so a fully-green plan is NOT proof the goal is met — ask the
            // model to confirm before answering, never push a premature "give the final answer now".
            return isDynamic
                ? "The planned steps have run. Confirm the goal is actually met before answering — if not, continue with the best next action."
                : "Recipe \"\(title)\": all \(steps.count) steps are done. Give the final answer now."
        }
        let done = cursor == 0 ? "none yet" : (cursor == 1 ? "step 1" : "steps 1–\(cursor)")
        let next = steps[cursor]
        if isDynamic {
            // H2/H4: phrase a dynamic suggestion as ABANDONABLE — the plan may be wrong, so the model must
            // stay free to pick a better tool. (After 2 non-advancing turns the loop drops this line
            // entirely for the neutral goal restatement — see AgentLoop's `dynamicStalls`.) No firm
            // "suggested tool" whisper, no purpose echo — just a soft hint plus the real decision ask.
            return "Plan so far: \(done) of \(steps.count) done. Likely next — \(next.title) (try \(next.toolHint); if a different tool clearly fits better, use that instead). Decide the single best next action."
        }
        var line = "Recipe \"\(title)\" (\(steps.count) steps). Done: \(done). "
        line += "Next is step \(cursor + 1) — \(next.title) (suggested tool: \(next.toolHint))."
        if let g = next.guidance { line += " \(g)" }
        line += " Decide the single best next action."
        return line
    }
}
