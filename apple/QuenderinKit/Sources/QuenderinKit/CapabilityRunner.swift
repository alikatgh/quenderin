import Foundation

/// Per-capability consent grants (AGENT_AUTONOMY_PLAN §3.3). Granted BY THE USER in settings —
/// never by code paths reachable from model output, and never auto-granted on first use.
public protocol ConsentStore: Sendable {
    func isGranted(_ capabilityID: String) -> Bool
    func setGranted(_ capabilityID: String, _ granted: Bool)
}

/// Test/default store — nothing granted until a test grants it.
public final class InMemoryConsentStore: ConsentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Set<String> = []

    public init() {}

    public func isGranted(_ capabilityID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return granted.contains(capabilityID)
    }

    public func setGranted(_ capabilityID: String, _ isGranted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isGranted { granted.insert(capabilityID) } else { granted.remove(capabilityID) }
    }
}

/// The persistent store the capabilities pane (Milestone 0 step 5) reads and writes.
public final class UserDefaultsConsentStore: ConsentStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static func key(_ id: String) -> String { "quenderin.consent.\(id)" }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isGranted(_ capabilityID: String) -> Bool {
        defaults.bool(forKey: Self.key(capabilityID))
    }

    public func setGranted(_ capabilityID: String, _ granted: Bool) {
        defaults.set(granted, forKey: Self.key(capabilityID))
    }
}

/// Bridges the runner's async "may I?" to a SwiftUI dialog: the runner awaits `request`,
/// the view observes `pending` and calls `resolve`. One question at a time (the agent loop is
/// sequential). Dismissal without answering resolves to NO — the safe reading of silence.
public final class ApprovalBroker: ObservableObject, @unchecked Sendable {
    @MainActor @Published public private(set) var pending: ActionPreview?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Autopilot state for the CURRENT run: when set, `request` answers yes without a dialog.
    /// Scoped per run — `beginRun` resets it, so one goal's grant can never leak into the next.
    private var autoApprove = false

    public init() {}

    /// Start-of-run reset (AgentSession.run): autopilot ON pre-approves the whole run, OFF
    /// restores the ask-per-action cadence. See `AgentAutopilot` for what autopilot does and
    /// does not skip — the blocklist/consent/ledger gates are upstream and unaffected.
    public func beginRun(autopilot: Bool) {
        lock.lock()
        autoApprove = autopilot
        lock.unlock()
    }

    /// Whether the current run is auto-approving (the view can show an autopilot hint).
    public var isAutoApproving: Bool {
        lock.lock(); defer { lock.unlock() }
        return autoApprove
    }

    /// Called by the runner (any context). Suspends until the user answers — unless this run
    /// is in autopilot, in which case it answers yes immediately (no dialog published).
    /// (`isAutoApproving` is a synchronous accessor — NSLock must not be taken directly in an
    /// async context, and the critical section holds no suspension point.)
    public func request(_ preview: ActionPreview) async -> Bool {
        if isAutoApproving { return true }
        return await withCheckedContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()
            Task { @MainActor in self.pending = preview }
        }
    }

    /// "Allow all steps for this goal" — approve the pending action AND every later one in
    /// this run. The mid-run upgrade for a user who trusts the goal and wants to walk away.
    @MainActor
    public func resolveAllForRun() {
        lock.lock()
        autoApprove = true
        lock.unlock()
        resolve(true)
    }

    /// Called by the UI on the user's answer (or on dialog dismissal, with `false`).
    @MainActor
    public func resolve(_ approved: Bool) {
        pending = nil
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: approved)
    }
}

/// The enforcement point (AGENT_AUTONOMY_PLAN §6): every capability invocation goes
/// gate → (refuse | run) → ledger, in that order, with NO path around it. The agent loop calls
/// this instead of `capability.run` directly. Returns the observation string the loop feeds back
/// to the model — refusals are worded so the model (and the run log) understand why.
public struct CapabilityRunner: Sendable {
    private let consent: ConsentStore
    private let ledger: AuditLedger
    private let now: @Sendable () -> Date
    /// Per-RUN approval for MUTATING capabilities (T2+): shown the preview, returns the user's
    /// yes/no. FAIL-CLOSED: when no approver is wired (nil — e.g. a headless surface), a
    /// mutating capability is refused outright. Consent-in-Settings says "this power may
    /// exist"; this says "yes, do THIS one, now" — the Shortcuts distinction, kept.
    private let approve: (@Sendable (ActionPreview) async -> Bool)?

    /// The run's reversible tail: successful mutating runs of `UndoableCapability`s are recorded
    /// here so "undo this task" can reverse them LIFO. Nil = no session tracking (tests, T0 surfaces).
    private let session: RunSession?

    public init(consent: ConsentStore = InMemoryConsentStore(),
                ledger: AuditLedger = InMemoryAuditLedger(),
                approve: (@Sendable (ActionPreview) async -> Bool)? = nil,
                session: RunSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.consent = consent
        self.ledger = ledger
        self.approve = approve
        self.session = session
        self.now = now
    }

    public func execute(_ capability: Capability, input: String) async -> String {
        func log(_ decision: String, outcome: String?) {
            ledger.append(AuditEntry(timestamp: now(), capability: capability.name,
                                     tier: capability.tier.rawValue, input: input,
                                     decision: decision, outcome: outcome))
        }

        let decision: GateDecision
        do {
            decision = try await CapabilityGate.assess(capability, input: input,
                                                       isConsented: consent.isGranted(capability.name))
        } catch {
            log("error", outcome: "preview failed: \(error)")
            let label = CapabilityCatalog.displayName(for: capability.name)
            return "Couldn't prepare “\(label)”: \(error)"
        }

        switch decision {
        case .blocked(let keyword):
            log("blocked(\(keyword))", outcome: nil)
            return "Refused: that step touches a blocked action (‘\(keyword)’)."
        case .needsConsent:
            // Prefix is stable for AgentLoop.isPermissionRefusal — body is human (display name, not tool id).
            log("needsConsent", outcome: nil)
            let label = CapabilityCatalog.displayName(for: capability.name)
            return "Needs your permission first: turn on “\(label)” in Settings → Agent, then try again."
        case .allowed(let preview):
            // The write gate: a mutating action needs the user's yes for THIS run, not just a
            // standing grant. No approver wired ⇒ refuse (fail closed), never silently write.
            if preview.mutates {
                // (single-action path — plans batch their approval in executePlan)
                guard let approve else {
                    log("needsApproval", outcome: nil)
                    return "This would change something on your Mac, but this screen can’t ask you to confirm. Nothing was done."
                }
                guard await approve(preview) else {
                    log("declined", outcome: nil)
                    return "You declined: \(preview.summary) Nothing was changed."
                }
            }
            do {
                let result = try await capability.run(input)
                log("allowed", outcome: result)
                // Record the reversible tail AFTER success only — a failed run has nothing to undo.
                if preview.mutates, let undoable = capability as? any UndoableCapability {
                    session?.record(undoable, input: input)
                }
                return await annotateWithVerification(capability, input: input, result: result)
            } catch {
                log("error", outcome: "\(error)")
                return "Tool error: \(error)"
            }
        }
    }

    /// Advisory post-condition: if the capability can verify itself and reports the action didn't
    /// visibly take, annotate the observation the agent reads + ledger an 'unverified' note. Never
    /// undoes anything (it already ran) — "the agent checks its own work", not a rollback. Best-
    /// effort: verification is guarded so a non-verifiable capability is untouched, and the check is
    /// purely advisory. Twin of the TS runner's `annotateWithVerification`.
    private func annotateWithVerification(_ capability: Capability, input: String, result: String) async -> String {
        guard let verifiable = capability as? any VerifiableCapability else { return result }
        let v = await verifiable.verify(input)
        guard !v.ok else { return result }
        ledger.append(AuditEntry(timestamp: now(), capability: capability.name,
                                 tier: capability.tier.rawValue, input: input,
                                 decision: "unverified", outcome: v.detail))
        return "\(result)\n(Couldn't confirm it worked: \(v.detail))"
    }

    /// Execute a multi-step PLAN with ONE aggregate approval (Milestone 3 — the Cowork UX).
    /// All-or-nothing pre-flight: every item is blocklist- and consent-checked and previewed
    /// BEFORE anything runs; one bad item refuses the whole plan (a plan containing a blocked
    /// step is a bad plan, not a plan to trim). If any step mutates, the user approves the whole
    /// numbered plan once (fail-closed without an approver). Execution is sequential, each step
    /// individually ledgered; a failing step stops the remainder and says how far it got.
    public func executePlan(_ items: [(capability: Capability, input: String)]) async -> String {
        func log(_ item: (capability: Capability, input: String), _ decision: String, outcome: String?) {
            ledger.append(AuditEntry(timestamp: now(), capability: item.capability.name,
                                     tier: item.capability.tier.rawValue, input: item.input,
                                     decision: decision, outcome: outcome))
        }

        // ── Pre-flight every step, before any approval or execution.
        var previews: [ActionPreview] = []
        for item in items {
            if let hit = SafetyBlocklist.matches(in: item.input).first {
                log(item, "blocked(\(hit))", outcome: nil)
                return "Refused: step \(previews.count + 1) touches a blocked action ('\(hit)'). Nothing was done."
            }
            if item.capability.requiresConsent && !consent.isGranted(item.capability.name) {
                log(item, "needsConsent", outcome: nil)
                let label = CapabilityCatalog.displayName(for: item.capability.name)
                return "Needs your permission first: turn on “\(label)” in Settings → Agent, then try again. Nothing was done."
            }
            guard let preview = try? await item.capability.plan(item.input) else {
                let label = CapabilityCatalog.displayName(for: item.capability.name)
                return "Couldn't prepare step \(previews.count + 1) (“\(label)”). Nothing was done."
            }
            previews.append(preview)
        }

        // ── One aggregate approval when anything writes.
        if previews.contains(where: \.mutates) {
            let numbered = previews.enumerated()
                .map { "\($0.offset + 1). \($0.element.summary)" }
                .joined(separator: "\n")
            let combined = ActionPreview(summary: "The agent proposes this plan:\n\(numbered)", mutates: true)
            guard let approve else {
                for item in items { log(item, "needsApproval", outcome: nil) }
                return "This plan would change something on your Mac, but this screen can’t ask you to confirm. Nothing was done."
            }
            guard await approve(combined) else {
                for item in items { log(item, "declined", outcome: nil) }
                return "You declined the plan. Nothing was changed."
            }
        }

        // ── Execute sequentially; a failure stops the remainder honestly.
        var results: [String] = []
        for (index, item) in items.enumerated() {
            do {
                let result = try await item.capability.run(item.input)
                log(item, "allowed", outcome: result)
                if previews[index].mutates, let undoable = item.capability as? any UndoableCapability {
                    session?.record(undoable, input: item.input)
                }
                results.append("\(index + 1). \(result)")
            } catch {
                log(item, "error", outcome: "\(error)")
                results.append("\(index + 1). Failed: \(error)")
                results.append("Stopped after step \(index + 1) of \(items.count).")
                break
            }
        }
        return results.joined(separator: "\n")
    }
}
