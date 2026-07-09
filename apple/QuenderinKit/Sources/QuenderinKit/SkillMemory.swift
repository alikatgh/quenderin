import Foundation

/// One proven skill: the ordered capability names that got a past goal to an answer.
public struct SkillRecord: Sendable, Equatable, Codable {
    public let goal: String
    public let tools: [String]
    public init(goal: String, tools: [String]) { self.goal = goal; self.tools = tools }
}

/// Skill memory — the reliability-compounding loop, and the honest answer to a weak local model's
/// #1 struggle (choosing the right tool). After a task SUCCEEDS, record goal → the tools that got
/// there; prime the next SIMILAR goal with that proven sequence. The agent gets reliably better at
/// chores you repeat, locally, with no bigger model. Retrieval-augmented planning — the recalled
/// sequence is a HINT the model still reasons over, and every step still goes through the full gate,
/// so it's safe by construction.
///
/// Pure policy (the app edge persists the `snapshot()` via UserDefaults, like `AgentGoalHistoryStore`).
/// Byte-faithful twin of the desktop `SkillMemory` (src/) and the Kotlin `SkillMemory` — same
/// tokenization (ASCII `[a-z0-9]`, length > 2), same overlap-coefficient similarity, same caps.
public struct SkillMemory: Sendable {
    private var records: [SkillRecord] = []
    /// Below this goal-similarity a past skill isn't offered (avoid irrelevant priming).
    private let threshold: Double
    /// Cap memory so it can't grow unbounded; oldest drop first.
    private let capacity: Int

    public init(threshold: Double = 0.5, capacity: Int = 200) {
        self.threshold = threshold
        self.capacity = capacity
    }

    public var size: Int { records.count }

    /// Remember that `tools` accomplished `goal`. Ignores empty runs; de-dupes an identical goal
    /// (keeps the most recent tool sequence for it).
    public mutating func record(goal: String, tools: [String]) {
        let g = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxGoalLen))
        if g.isEmpty || tools.isEmpty { return }
        records.removeAll { $0.goal.lowercased() == g.lowercased() }
        records.append(SkillRecord(goal: g, tools: Array(tools.prefix(Self.maxTools))))
        while records.count > capacity { records.removeFirst() }
    }

    /// The most similar past skills to `goal`, best first (up to `k`), above the threshold.
    public func recall(goal: String, k: Int = 2) -> [SkillRecord] {
        let target = Self.tokens(goal)
        return records
            .map { (record: $0, score: Self.similarity(target, Self.tokens($0.goal))) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map { $0.record }
    }

    /// A copy of the records — for persisting across sessions (the loop is only real if memory survives
    /// a restart).
    public func snapshot() -> [SkillRecord] { records }

    /// Replace the records from a persisted snapshot (validated + re-capped — an untrusted/hand-edited
    /// file can't bloat the planner preamble via `recall`, Q-280).
    public mutating func restore(_ snapshot: [SkillRecord]) {
        records = []
        for r in snapshot {
            records.append(SkillRecord(goal: String(r.goal.prefix(Self.maxGoalLen)),
                                       tools: Array(r.tools.prefix(Self.maxTools))))
            if records.count >= capacity { break }
        }
    }

    // MARK: - Pure twin policy (identical on desktop + Kotlin)

    static let maxGoalLen = 300
    static let maxTools = 40

    /// Lowercase ASCII word tokens (length > 2), deduped — the unit of goal similarity. ASCII `[a-z0-9]`
    /// exactly like the TS twin's `/[^a-z0-9]+/` split (NOT Unicode `isLetter`, which would diverge on
    /// accented text).
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !(($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")) }
            .map(String.init)
            .filter { $0.count > 2 })
    }

    /// Overlap coefficient: |A∩B| / min(|A|,|B|) — robust when goals differ in length.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let shared = a.reduce(into: 0) { if b.contains($1) { $0 += 1 } }
        return Double(shared) / Double(min(a.count, b.count))
    }
}
