import Foundation

/// The app edge of `SkillMemory` — owns the policy value + persists its snapshot across launches
/// (UserDefaults JSON), so "the agent gets better at chores you repeat" survives a restart. Thread-safe
/// (the agent loop recalls at the start of a run and records at the end, possibly off the main actor).
/// Twin of the desktop's on-disk agent-skills.json + the Android SkillMemoryStore (SharedPreferences).
/// @unchecked Sendable: all mutable state is behind `lock`; UserDefaults is itself thread-safe.
public final class SkillMemoryStore: @unchecked Sendable {
    public static let shared = SkillMemoryStore()

    private let lock = NSLock()
    private var memory: SkillMemory
    private let defaultsKey = "quenderin.skillMemory"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var m = SkillMemory()
        if let data = defaults.data(forKey: defaultsKey),
           let snapshot = try? JSONDecoder().decode([SkillRecord].self, from: data) {
            m.restore(snapshot)   // re-caps untrusted rows (Q-280)
        }
        self.memory = m
    }

    /// Proven sequences for goals similar to `goal` (primes the planner preamble).
    public func recall(_ goal: String) -> [SkillRecord] {
        lock.lock(); defer { lock.unlock() }
        return memory.recall(goal: goal)
    }

    /// Remember a successful run's tool sequence, then persist. Called once per answered run.
    public func record(goal: String, tools: [String]) {
        lock.lock()
        memory.record(goal: goal, tools: tools)
        let snapshot = memory.snapshot()
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
