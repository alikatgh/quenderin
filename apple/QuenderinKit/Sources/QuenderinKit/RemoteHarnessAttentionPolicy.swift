import Foundation

/// Local destination only, never a notification URL or execution authorization. IDs are opaque.
public struct RemoteHarnessAttentionScope: Sendable, NativeConnectionPrivateValue {
    public let origin: String
    public let clientDeviceID: String
    public let hostID: String
    public let hostFingerprint: String
    public let workspaceID: String
    public let sessionID: String
    public init(origin: String, clientDeviceID: String, hostID: String, hostFingerprint: String, workspaceID: String, sessionID: String) {
        self.origin = origin; self.clientDeviceID = clientDeviceID; self.hostID = hostID
        self.hostFingerprint = hostFingerprint; self.workspaceID = workspaceID; self.sessionID = sessionID
    }
    /// Reuse authenticated carrier bindings; construction alone does not authenticate a scope.
    public init(origin: String, hostFingerprint: String, binding: RemoteHarnessBinding) {
        self.init(origin: origin, clientDeviceID: binding.clientDeviceID ?? "", hostID: binding.hostID,
                  hostFingerprint: hostFingerprint, workspaceID: binding.workspaceID ?? "", sessionID: binding.sessionID ?? "")
    }
    fileprivate var components: [String] { [origin, clientDeviceID, hostID, hostFingerprint, workspaceID, sessionID] }
    fileprivate var valid: Bool {
        guard let canonical = try? NativeConnectionOrigin.canonical(origin), origin.utf8.elementsEqual(canonical.utf8),
              [clientDeviceID, hostID, workspaceID, sessionID].allSatisfy(Self.validID),
              (try? NativeConnectionBounds.digest(hostFingerprint)) != nil else { return false }
        return true
    }
    // Same bounds as Kotlin's existing rhID, without normalizing Unicode identifiers.
    fileprivate static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 256 && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    fileprivate func exactlyMatches(_ other: Self) -> Bool {
        zip(components, other.components).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
    }
}

/// Future negotiated input supplied ONLY after channel authentication and event validation.
/// The default rejects unvalidated input. Transcript changes do not imply upstream support.
/// No transcript, question, tool arguments, arbitrary URL or action can enter this value.
public struct RemoteHarnessAttentionEvent: Sendable, NativeConnectionPrivateValue {
    public let scope: RemoteHarnessAttentionScope
    public let generation: UInt64
    public let eventID: String
    public let kind: String
    public let issuedAtEpochMilliseconds: Int64
    public let expiresAtEpochMilliseconds: Int64
    public let authenticatedAndNegotiated: Bool
    public let historical: Bool
    public init(scope: RemoteHarnessAttentionScope, generation: UInt64, eventID: String, kind: String,
                issuedAtEpochMilliseconds: Int64, expiresAtEpochMilliseconds: Int64,
                authenticatedAndNegotiated: Bool = false, historical: Bool = false) {
        self.scope = scope; self.generation = generation; self.eventID = eventID; self.kind = kind
        self.issuedAtEpochMilliseconds = issuedAtEpochMilliseconds; self.expiresAtEpochMilliseconds = expiresAtEpochMilliseconds
        self.authenticatedAndNegotiated = authenticatedAndNegotiated; self.historical = historical
    }
}
public enum RemoteHarnessAttentionDisposition: String, Sendable { case suppress, inApp, systemIntent = "system" }
public enum RemoteHarnessAttentionReason: String, Sendable {
    case clock, unvalidated, invalidScope, wrongDestination, staleGeneration, invalidEvent, invalidTime, expired
    case duplicate, capacity, history, disabled, viewed, eligible
}
/// Generic copy and opaque local routing IDs only. No execution capability is exposed.
public struct RemoteHarnessAttentionPayload: Sendable, NativeConnectionPrivateValue {
    public let eventID: String
    public let sessionID: String
    public let title = "Remote Harness"
    public let body = "A remote session needs your attention."
}
public struct RemoteHarnessAttentionDecision: Sendable, NativeConnectionPrivateValue {
    public let disposition: RemoteHarnessAttentionDisposition
    public let reason: RemoteHarnessAttentionReason
    public let payload: RemoteHarnessAttentionPayload?
    public var authorizesExecution: Bool { false }
}

/// Pure opt-in policy, NOT OS push integration: no delivery, registration, permission UI or service.
/// A system intent is only a local result for a future adapter. Approvals never authorize work.
/// Supply the current authenticated scope/generation and both clocks for every evaluation.
/// Retain this owner across reconnects. Replay memory is process-local, not durable push storage.
@MainActor public final class RemoteHarnessAttentionPolicy: NativeConnectionPrivateValue {
    public static let maximumRemembered = 256
    public static let maximumEventLifetimeMilliseconds: Int64 = 600_000
    // String equality/hashing in Swift merges canonical equivalents. Data preserves exact UTF8.
    private struct Key: Hashable { let scope: [Data]; let eventID: Data }
    private struct Entry { let expiresAt: Int64; let monotonicDeadline: Int64 }
    private var remembered: [Key: Entry] = [:]
    private var lastEpoch: Int64?
    private var lastMonotonic: Int64?
    private var lastEffectiveEpoch: Int64?
    public var rememberedCount: Int { remembered.count }
    public init() {}

    public func evaluate(event: RemoteHarnessAttentionEvent, currentScope: RemoteHarnessAttentionScope, currentGeneration: UInt64,
                         nowEpochMilliseconds now: Int64, nowMonotonicMilliseconds monotonic: Int64, enabled: Bool = false,
                         foreground: Bool, viewedScope: RemoteHarnessAttentionScope? = nil) -> RemoteHarnessAttentionDecision {
        func suppress(_ reason: RemoteHarnessAttentionReason) -> RemoteHarnessAttentionDecision {
            RemoteHarnessAttentionDecision(disposition: .suppress, reason: reason, payload: nil)
        }
        let maximum = NativeConnectionBounds.counter
        guard (1...maximum).contains(now), (0...maximum).contains(monotonic),
              lastEpoch.map({ now >= $0 }) ?? true, lastMonotonic.map({ monotonic >= $0 }) ?? true else { return suppress(.clock) }
        let elapsed = lastMonotonic.map { monotonic - $0 } ?? 0
        let previousEffective = lastEffectiveEpoch ?? now
        guard previousEffective <= maximum - elapsed else { return suppress(.clock) }
        // A frozen/adjusted wall clock cannot extend an event or reopen an expired dedup slot.
        let effectiveNow = max(now, previousEffective + elapsed)
        lastEpoch = now; lastMonotonic = monotonic; lastEffectiveEpoch = effectiveNow
        remembered = remembered.filter { effectiveNow < $0.value.expiresAt && monotonic < $0.value.monotonicDeadline }
        guard event.authenticatedAndNegotiated else { return suppress(.unvalidated) }
        guard event.scope.valid, currentScope.valid else { return suppress(.invalidScope) }
        guard event.scope.exactlyMatches(currentScope) else { return suppress(.wrongDestination) }
        guard currentGeneration > 0, currentGeneration <= UInt64(maximum), event.generation == currentGeneration else { return suppress(.staleGeneration) }
        guard RemoteHarnessAttentionScope.validID(event.eventID), ["turn-ended", "failed", "stopped", "approval", "question"].contains(event.kind) else { return suppress(.invalidEvent) }
        let issued = event.issuedAtEpochMilliseconds, expires = event.expiresAtEpochMilliseconds
        // Bounds/order precede arithmetic, including values near integer limits.
        guard (1...maximum).contains(issued), (1...maximum).contains(expires), expires > issued,
              expires - issued <= Self.maximumEventLifetimeMilliseconds, issued <= now else { return suppress(.invalidTime) }
        guard expires > effectiveNow else { return suppress(.expired) }
        let remaining = expires - effectiveNow
        guard monotonic <= maximum - remaining else { return suppress(.clock) }
        let key = Key(scope: event.scope.components.map { Data($0.utf8) }, eventID: Data(event.eventID.utf8))
        guard remembered[key] == nil else { return suppress(.duplicate) }
        guard remembered.count < Self.maximumRemembered else { return suppress(.capacity) }
        // Reserve suppressed/disabled/history events too, before any presentation decision.
        remembered[key] = Entry(expiresAt: expires, monotonicDeadline: monotonic + remaining)
        guard !event.historical else { return suppress(.history) }
        guard enabled else { return suppress(.disabled) }
        if foreground, viewedScope?.exactlyMatches(event.scope) == true { return suppress(.viewed) }
        return RemoteHarnessAttentionDecision(disposition: foreground ? .inApp : .systemIntent, reason: .eligible,
            payload: RemoteHarnessAttentionPayload(eventID: event.eventID, sessionID: event.scope.sessionID))
    }
}
