package ai.quenderin.core

/**
 * One goal the user has run — the text plus when it was last submitted (epoch ms).
 * Twin of Swift `AgentGoalEntry`.
 */
data class AgentGoalEntry(val goal: String, val lastUsedAt: Long)

/**
 * The RECENTS policy for agent goals — pure logic, twin of Swift `AgentGoalHistory` (kept in
 * behavioral lockstep; the Swift XCTests and the CoreVerify checks pin the same cases). A recents
 * list, not a log: re-running a goal MOVES it to the top instead of duplicating it, and the list
 * is capped so it never grows unbounded.
 *
 * Dedup is case-SENSITIVE exact match on the trimmed text — deliberately. A case-insensitive
 * compare needs a locale-neutral casefold on both platforms (Turkish dotless-i etc.), which is
 * exactly the cross-platform drift class the seam-normalization series eliminated; an occasional
 * "Convert…"/"convert…" pair in the list is a far smaller cost than divergent twins.
 *
 * Persistence lives at the app edge (the Compose layer serializes the list like it does the
 * conversation index); this object owns only the policy.
 */
object AgentGoalHistory {
    /** Enough to scroll back through a week of real use; small enough to render as one list. */
    const val MAX_ENTRIES = 20

    /** Record a submitted goal: trim → ignore empty → dedupe-to-top → cap. Newest first. */
    fun record(goal: String, timestampMs: Long, entries: List<AgentGoalEntry>): List<AgentGoalEntry> {
        val trimmed = goal.trim()
        if (trimmed.isEmpty()) return entries
        val next = ArrayList<AgentGoalEntry>(entries.size + 1)
        next.add(AgentGoalEntry(trimmed, timestampMs))
        entries.filterTo(next) { it.goal != trimmed }
        return if (next.size > MAX_ENTRIES) next.subList(0, MAX_ENTRIES).toList() else next
    }

    /** Remove one goal (exact trimmed match) — the per-row "Remove" affordance. */
    fun remove(goal: String, entries: List<AgentGoalEntry>): List<AgentGoalEntry> {
        val trimmed = goal.trim()
        return entries.filter { it.goal != trimmed }
    }
}
