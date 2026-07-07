import Foundation
import os

/// One goal the user has run — the text plus when it was last submitted (epoch ms, the same
/// Int64 convention as `ConversationSummary.updatedAt`).
public struct AgentGoalEntry: Sendable, Equatable, Codable {
    public let goal: String
    public let lastUsedAt: Int64

    public init(goal: String, lastUsedAt: Int64) {
        self.goal = goal
        self.lastUsedAt = lastUsedAt
    }
}

/// The RECENTS policy for agent goals — pure logic so it unit-tests on any platform and ports
/// verbatim to the Kotlin twin (`ai.quenderin.core.AgentGoalHistory`). A recents list, not a log:
/// re-running a goal MOVES it to the top instead of duplicating it, and the list is capped so it
/// never grows unbounded.
///
/// Dedup is case-SENSITIVE exact match on the trimmed text — deliberately. A case-insensitive
/// compare needs a locale-neutral casefold on both platforms (Turkish dotless-i etc.), which is
/// exactly the cross-platform drift class the seam-normalization series eliminated; an occasional
/// "Convert…"/"convert…" pair in the list is a far smaller cost than divergent twins.
public enum AgentGoalHistory {
    /// Enough to scroll back through a week of real use; small enough to render as one list.
    public static let maxEntries = 20

    /// Record a submitted goal: trim → ignore empty → dedupe-to-top → cap. Newest first.
    public static func record(_ goal: String, at timestampMs: Int64, into entries: [AgentGoalEntry]) -> [AgentGoalEntry] {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        var next = entries.filter { $0.goal != trimmed }
        next.insert(AgentGoalEntry(goal: trimmed, lastUsedAt: timestampMs), at: 0)
        if next.count > maxEntries { next.removeLast(next.count - maxEntries) }
        return next
    }

    /// Remove one goal (exact trimmed match) — the per-row "Remove" affordance.
    public static func remove(_ goal: String, from entries: [AgentGoalEntry]) -> [AgentGoalEntry] {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { $0.goal != trimmed }
    }

    /// Encode to a portable blob (same shape discipline as `ConversationStore`: the wire format
    /// is decoupled from any view model; the app owns where the blob lives).
    public static func encode(_ entries: [AgentGoalEntry]) throws -> Data {
        try JSONEncoder().encode(entries)
    }

    /// Decode a blob; empty/missing/corrupt data is an EMPTY history, never an error — losing
    /// a recents list must not break the agent screen.
    public static func decode(_ data: Data) -> [AgentGoalEntry] {
        guard !data.isEmpty, let entries = try? JSONDecoder().decode([AgentGoalEntry].self, from: data) else { return [] }
        return entries
    }
}

/// File-backed, observable edge for the goal history — loads at init, saves on every change
/// (atomic, error-logged like `FileConversationPersistence`; a silent `try?` would lose history
/// with no trace, Q-009). Views observe `entries`; tests pass a temp directory.
@MainActor
public final class AgentGoalHistoryStore: ObservableObject {
    public static let shared = AgentGoalHistoryStore()

    @Published public private(set) var entries: [AgentGoalEntry] = []

    private let fileURL: URL
    private static let log = Logger(subsystem: "org.quenderin", category: "agent-goals")

    /// - Parameter directory: where `agent-goals.json` lives. Defaults to Application Support
    ///   (beside the `conversations/` directory); tests pass a temp dir.
    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        self.fileURL = base.appendingPathComponent("agent-goals.json")
        self.entries = AgentGoalHistory.decode((try? Data(contentsOf: fileURL)) ?? Data())
    }

    /// Record a submitted goal (recents semantics — see `AgentGoalHistory.record`).
    public func record(_ goal: String) {
        entries = AgentGoalHistory.record(goal, at: Int64(Date().timeIntervalSince1970 * 1000), into: entries)
        save()
    }

    /// Remove one goal from the list.
    public func remove(_ goal: String) {
        entries = AgentGoalHistory.remove(goal, from: entries)
        save()
    }

    /// Forget everything — the user's one-tap privacy affordance.
    public func clear() {
        entries = []
        save()
    }

    private func save() {
        do {
            try AgentGoalHistory.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("saving agent goal history failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
