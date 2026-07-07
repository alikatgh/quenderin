import Foundation

/// The autonomy layer's core abstraction (docs/AGENT_AUTONOMY_PLAN.md §6). A `Capability` is an
/// `AgentTool` that additionally **declares its blast radius**, so the runtime can gate on the
/// DECLARATION — before ever calling `run` — instead of trusting the tool to behave. Every tool
/// we ship today is pure compute and becomes a T0 capability for free via the defaults below; a
/// capability must opt UP into risk and can never default into it. Twin of Kotlin `Capability`.

/// The risk tier the agent climbs one rung at a time (§4). Ordered: a higher tier is more
/// dangerous and more gated.
public enum CapabilityTier: Int, Sendable, Comparable, CaseIterable {
    case pureCompute = 0     // T0 — no side effects (calculator, unit/date)
    case readOnly = 1        // T1 — reads a resource the user pointed at; nothing written
    case reversibleWrite = 2 // T2 — writes that can be undone (scratch file, move-to-trash)
    case appAction = 3       // T3 — drives an app / fills (not submits) a form
    case irreversible = 4    // T4 — permanent delete, submit; NEVER autonomous

    public static func < (lhs: CapabilityTier, rhs: CapabilityTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a capability's `run` will touch — the runtime reads this to decide consent + preview.
public enum BlastRadius: Sendable, Equatable {
    case none                            // pure compute
    case read(resource: String)          // reads the named resource, no mutation
    case write(resource: String)         // reversible mutation
    case irreversible(resource: String)  // irreversible mutation

    public var mutates: Bool {
        switch self {
        case .none, .read: return false
        case .write, .irreversible: return true
        }
    }
}

/// A side-effect-free description of what running WOULD do — the Shortcuts "read the steps
/// before they run" property, made mandatory for T2+.
public struct ActionPreview: Sendable, Equatable {
    public let summary: String
    public let mutates: Bool
    public init(summary: String, mutates: Bool) {
        self.summary = summary
        self.mutates = mutates
    }
}

/// An `AgentTool` that declares its risk. Conform an existing pure-compute tool by simply
/// changing `: AgentTool` to `: Capability` — the T0 defaults below apply and behavior is
/// unchanged. Higher tiers override `tier`/`blastRadius`/`plan`.
public protocol Capability: AgentTool {
    var tier: CapabilityTier { get }
    var blastRadius: BlastRadius { get }
    /// True when the user must grant this capability before first use (everything above T0).
    var requiresConsent: Bool { get }
    /// Preview `run(input)` WITHOUT performing its side effect. Required for T2+; the T0 default
    /// simply states "no side effects".
    func plan(_ input: String) async throws -> ActionPreview
}

public extension Capability {
    var tier: CapabilityTier { .pureCompute }
    var blastRadius: BlastRadius { .none }
    var requiresConsent: Bool { tier > .pureCompute }
    func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "\(name): computes locally, no side effects.", mutates: false)
    }
}

/// A capability whose successful run can be REVERSED — the generic half of the trust loop's
/// undo (the file-move `UndoJournal` predates this and stays for fs.*). `undo(input)` receives
/// the SAME input the successful `run(input)` did and plays the inverse (delete the reminder it
/// added, remove the calendar event it made). Twin of the TS capabilities' optional `undo`.
public protocol UndoableCapability: Capability {
    /// Reverse a previously successful `run(input)`. Returns a human-readable report.
    func undo(_ input: String) async throws -> String
}

/// One task's reversible tail — every successful MUTATING run of an `UndoableCapability` is
/// recorded here, and `undoAll()` reverses them newest-first (LIFO). The Swift twin of the TS
/// `RunSession` that powers "undo this task" on the desktop lab/CLI.
public final class RunSession: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(capability: any UndoableCapability, input: String)] = []

    public init() {}

    public func record(_ capability: any UndoableCapability, input: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append((capability, input))
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.count
    }

    /// Snapshot-and-clear, synchronously — manual NSLock is banned in async contexts, so the
    /// async `undoAll` takes its LIFO batch through this sync helper.
    private func drain() -> [(capability: any UndoableCapability, input: String)] {
        lock.lock(); defer { lock.unlock() }
        let items = Array(recorded.reversed())
        recorded = []
        return items
    }

    /// Reverse everything this session recorded, newest-first. Best-effort: a failed reversal is
    /// reported and the rest still roll back. Drains the session (undo can't double-apply).
    public func undoAll() async -> String {
        let toUndo = drain()
        var lines: [String] = []
        for item in toUndo {
            do {
                lines.append(try await item.capability.undo(item.input))
            } catch {
                lines.append("Couldn't undo \(item.capability.name) (\(item.input)): \(error)")
            }
        }
        return lines.isEmpty ? "Nothing to undo." : lines.joined(separator: "\n")
    }
}

/// The ordered pre-flight decision, computed WITHOUT running the capability (§6).
public enum GateDecision: Sendable, Equatable {
    case blocked(keyword: String)     // input touches the safety blocklist — refuse outright
    case needsConsent(ActionPreview)  // tier requires a grant the user hasn't given
    case allowed(ActionPreview)       // safe to run
}

/// The safety spine's decision function — PURE, no side effects, no persistence. It composes the
/// (now unified) `SafetyBlocklist`, the capability's consent requirement, and its preview into the
/// ordered gate from AGENT_AUTONOMY_PLAN §6. The caller executes the capability ONLY on `.allowed`.
/// Consent state is passed in (`isConsented`) — persisting grants is a later Milestone 0 step.
public enum CapabilityGate {
    public static func assess(_ capability: Capability, input: String, isConsented: Bool) async throws -> GateDecision {
        // 1. Blocklist first — a blocked action is refused regardless of tier or consent.
        if let hit = SafetyBlocklist.matches(in: input).first {
            return .blocked(keyword: hit)
        }
        // 2. Preview (side-effect-free) so the caller can show it in either outcome.
        let preview = try await capability.plan(input)
        // 3. Consent gate for anything above pure compute.
        if capability.requiresConsent && !isConsented {
            return .needsConsent(preview)
        }
        return .allowed(preview)
    }
}
