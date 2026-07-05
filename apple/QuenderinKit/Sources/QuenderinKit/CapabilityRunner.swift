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

/// The enforcement point (AGENT_AUTONOMY_PLAN §6): every capability invocation goes
/// gate → (refuse | run) → ledger, in that order, with NO path around it. The agent loop calls
/// this instead of `capability.run` directly. Returns the observation string the loop feeds back
/// to the model — refusals are worded so the model (and the run log) understand why.
public struct CapabilityRunner: Sendable {
    private let consent: ConsentStore
    private let ledger: AuditLedger
    private let now: @Sendable () -> Date

    public init(consent: ConsentStore = InMemoryConsentStore(),
                ledger: AuditLedger = InMemoryAuditLedger(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.consent = consent
        self.ledger = ledger
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
            return "Couldn't preview \(capability.name): \(error)"
        }

        switch decision {
        case .blocked(let keyword):
            log("blocked(\(keyword))", outcome: nil)
            return "Refused: touches a blocked action ('\(keyword)')."
        case .needsConsent(let preview):
            log("needsConsent", outcome: nil)
            return "Needs your permission first: \(preview.summary) Grant \"\(capability.name)\" in Settings to allow this."
        case .allowed:
            do {
                let result = try await capability.run(input)
                log("allowed", outcome: result)
                return result
            } catch {
                log("error", outcome: "\(error)")
                return "Tool error: \(error)"
            }
        }
    }
}
