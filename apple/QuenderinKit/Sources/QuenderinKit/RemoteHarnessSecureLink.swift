import Foundation

private func secureLinkID(_ value: String) throws {
    guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= 1_024 else { throw RemoteHarnessSecureLinkError.identity }
}
// Opaque protocol identifiers compare encoded bytes, never Unicode canonical equivalence.
private func secureLinkEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
private func secureLinkEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) { case (nil, nil): return true; case let (a?, b?): return secureLinkEqual(a, b); default: return false }
}
private func secureLinkEqual(_ lhs: RemoteHarnessBinding, _ rhs: RemoteHarnessBinding) -> Bool {
    lhs.generation == rhs.generation && secureLinkEqual(lhs.hostID, rhs.hostID) &&
        secureLinkEqual(lhs.workspaceID, rhs.workspaceID) && secureLinkEqual(lhs.sessionID, rhs.sessionID)
}
public enum RemoteHarnessSecureLinkError: String, Error, Sendable, CustomStringConvertible {
    case identity, generation, binding, notReady, failed
    public var description: String { "Remote Harness secure link: \(rawValue)" }
}
public struct RemoteHarnessSecureClientID: Sendable, NativeConnectionPrivateValue {
    public let value: String
    public init(_ value: String) throws { try secureLinkID(value); self.value = value }
}
public struct RemoteHarnessSecureHostID: Sendable, NativeConnectionPrivateValue {
    public let value: String
    public init(_ value: String) throws { try secureLinkID(value); self.value = value }
}
public struct RemoteHarnessSecureConnectionInfo: Sendable, NativeConnectionPrivateValue {
    public let connectionID: String
    public let localDeviceID: String
    public let remoteDeviceID: String
    public init(connectionID: String, localDeviceID: String, remoteDeviceID: String) throws {
        try secureLinkID(connectionID); try secureLinkID(localDeviceID); try secureLinkID(remoteDeviceID)
        self.connectionID = connectionID; self.localDeviceID = localDeviceID; self.remoteDeviceID = remoteDeviceID
    }
}
/// Opaque reference to already trusted identity/key material; this API has no key export.
@MainActor public protocol RemoteHarnessSecureIdentity: AnyObject {}
/// Caller must first verify account membership, Host role, pin and durable enrollment.
/// Constructing this context is NOT evidence that those checks occurred.
@MainActor public struct RemoteHarnessSecureEnrollment: NativeConnectionPrivateValue {
    public let client: RemoteHarnessSecureClientID
    public let host: RemoteHarnessSecureHostID
    public let identity: any RemoteHarnessSecureIdentity
    public init(client: RemoteHarnessSecureClientID, host: RemoteHarnessSecureHostID, identity: any RemoteHarnessSecureIdentity) {
        self.client = client; self.host = host; self.identity = identity
    }
}
public struct RemoteHarnessSecureNoiseContext: Sendable, NativeConnectionPrivateValue {
    public let pattern = "Noise_IK_25519_ChaChaPoly_SHA256"
    public let prologue: Data
    init(_ info: RemoteHarnessSecureConnectionInfo) {
        prologue = Data("DSH-REMOTE\0v=1\0connection=\(info.connectionID)\0host=\(info.remoteDeviceID)\0client=\(info.localDeviceID)".utf8)
    }
}
public struct RemoteHarnessSecureHandshake: Sendable, NativeConnectionPrivateValue {
    public let connectionID: String
    public let targetDeviceID: String
    public let step: Int
    public let bytes: Data
    public init(connectionID: String, targetDeviceID: String, step: Int, bytes: Data) throws {
        try secureLinkID(connectionID); try secureLinkID(targetDeviceID)
        guard bytes.count <= 65_535 else { throw RemoteHarnessSecureLinkError.failed }
        self.connectionID = connectionID; self.targetDeviceID = targetDeviceID; self.step = step; self.bytes = bytes
    }
}
public struct RemoteHarnessSecureRelay: Sendable, NativeConnectionPrivateValue {
    public let connectionID: String
    public let targetDeviceID: String
    public let counter: Int64
    public let ciphertext: Data
    public init(connectionID: String, targetDeviceID: String, counter: Int64, ciphertext: Data) throws {
        try secureLinkID(connectionID); try secureLinkID(targetDeviceID)
        guard ciphertext.count <= 65_535 else { throw RemoteHarnessSecureLinkError.failed }
        self.connectionID = connectionID; self.targetDeviceID = targetDeviceID; self.counter = counter; self.ciphertext = ciphertext
    }
}
public struct RemoteHarnessSecureHandshakeResult: Sendable, NativeConnectionPrivateValue {
    public let complete: Bool
    public let payload: Data
    public let response: Data?
    public init(complete: Bool, payload: Data, response: Data? = nil) throws {
        guard payload.count <= 65_535, (response?.count ?? 0) <= 65_535 else { throw RemoteHarnessSecureLinkError.failed }
        self.complete = complete; self.payload = payload; self.response = response
    }
}
public struct RemoteHarnessSecureCounters: Sendable, NativeConnectionPrivateValue {
    public let complete: Bool
    public let sending: Int64
    public let receiving: Int64
    public init(complete: Bool, sending: Int64, receiving: Int64) {
        self.complete = complete; self.sending = sending; self.receiving = receiving
    }
}
@MainActor public protocol RemoteHarnessSecureNoise: AnyObject {
    func initiate(emptyPayload: Data) throws -> Data
    func readHandshake(_ bytes: Data) throws -> RemoteHarnessSecureHandshakeResult
    func counters() throws -> RemoteHarnessSecureCounters
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data) throws -> Data
    func shutdown() throws
}
@MainActor public protocol RemoteHarnessSecureNoiseFactory: AnyObject {
    func makeInitiator(enrollment: RemoteHarnessSecureEnrollment, info: RemoteHarnessSecureConnectionInfo,
                       context: RemoteHarnessSecureNoiseContext) throws -> any RemoteHarnessSecureNoise
}
/// Decoded-byte seam only. A future JSON/WSS adapter owns canonical unpadded Base64URL,
/// 64 KiB control / 1 MiB relay JSON bounds, account authentication and network I/O.
/// Sending is a bounded handoff, not evidence of socket delivery. Every callback must
/// retain the original generation, including asynchronous failures and retirement.
@MainActor public protocol RemoteHarnessSecurePacketPort: AnyObject {
    func connectionInfo() throws -> RemoteHarnessSecureConnectionInfo
    func sendHandshake(_ payload: RemoteHarnessSecureHandshake, generation: UInt64) throws
    func sendRelay(_ payload: RemoteHarnessSecureRelay, generation: UInt64) throws
    func retire(generation: UInt64) throws
}
public enum RemoteHarnessSecureRetirement: String, Sendable { case closed, replaced, handshake, deadline, clock, counter, receive, send, limit, observer }
@MainActor public protocol RemoteHarnessSecureObserver: AnyObject {
    func authenticated(binding: RemoteHarnessBinding) throws
    func receivedBusinessBytes(_ bytes: Data, binding: RemoteHarnessBinding) throws
    func retired(binding: RemoteHarnessBinding, reason: RemoteHarnessSecureRetirement) throws
}

/// Source-only owner: no crypto implementation, real authentication, scheduler, retries or reconnect.
/// Caller MUST drive checkDeadlines during idle periods and retain the original generation
/// in every asynchronous callback. Existing coordinator can attach through the observer/port.
@MainActor public final class RemoteHarnessSecureLink: RemoteHarnessBusinessPort, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let handshakeMilliseconds: Int64 = 10_000
    public static let queueBytes = 8_388_608
    public static let queueMessages = 256
    public static let ciphertextBytes = 65_535
    public static let maximumCounter: Int64 = 9_007_199_254_740_991
    private enum Phase { case preparing, waiting, reading, ready }
    @MainActor private final class Session {
        let binding: RemoteHarnessBinding
        let enrollment: RemoteHarnessSecureEnrollment
        let fragments: RemoteHarnessFragments
        var info: RemoteHarnessSecureConnectionInfo?
        var noise: (any RemoteHarnessSecureNoise)?
        var phase = Phase.preparing
        var lastNow: Int64?
        var deadline: Int64?
        var sending: Int64 = 0
        var receiving: Int64 = 0
        var reading = false
        var draining = false
        var queue: [Data] = []
        var reservedBytes = 0
        var reservedMessages = 0
        init(binding: RemoteHarnessBinding, enrollment: RemoteHarnessSecureEnrollment) throws {
            self.binding = binding; self.enrollment = enrollment
            fragments = try RemoteHarnessFragments(authenticatedGeneration: binding.generation)
        }
    }
    private let port: any RemoteHarnessSecurePacketPort
    private let factory: any RemoteHarnessSecureNoiseFactory
    private let clock: any RemoteHarnessClock
    private let observer: any RemoteHarnessSecureObserver
    private var session: Session?
    private var maximumGeneration: UInt64 = 0
    private var teardownPending: UInt64?
    private var retiring = false
    public nonisolated var description: String { "RemoteHarnessSecureLink(redacted)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
    public var isReady: Bool { session?.phase == .ready }
    public var activeGeneration: UInt64? { session?.binding.generation }
    public var queuedByteCount: Int { session?.reservedBytes ?? 0 }
    public var queuedMessageCount: Int { session?.reservedMessages ?? 0 }
    public var unconfirmedRetirementGeneration: UInt64? { teardownPending }
    public init(port: any RemoteHarnessSecurePacketPort, factory: any RemoteHarnessSecureNoiseFactory,
                clock: any RemoteHarnessClock, observer: any RemoteHarnessSecureObserver) {
        self.port = port; self.factory = factory; self.clock = clock; self.observer = observer
    }
    public func begin(binding: RemoteHarnessBinding, enrollment: RemoteHarnessSecureEnrollment) throws {
        guard teardownPending == nil else { throw RemoteHarnessSecureLinkError.failed }
        guard binding.generation > maximumGeneration, binding.generation <= UInt64(Int64.max) else { throw RemoteHarnessSecureLinkError.generation }
        maximumGeneration = binding.generation // Reserve BEFORE old shutdown/observer callbacks.
        if let old = session { retire(old, reason: .replaced) }
        guard maximumGeneration == binding.generation, session == nil, teardownPending == nil else { throw RemoteHarnessSecureLinkError.generation }
        let s = try Session(binding: binding, enrollment: enrollment); session = s
        try guarded(s, reason: .handshake) {
            let info = try external(s) { try port.connectionInfo() }; s.info = info
            try require(secureLinkEqual(info.localDeviceID, enrollment.client.value) && secureLinkEqual(info.remoteDeviceID, enrollment.host.value) && secureLinkEqual(binding.hostID, enrollment.host.value))
            let noise = try factory.makeInitiator(enrollment: enrollment, info: info, context: RemoteHarnessSecureNoiseContext(info))
            if session !== s { try? noise.shutdown(); throw RemoteHarnessSecureLinkError.generation }
            s.noise = noise
            try counters(s, complete: false)
            let time = try now(s)
            try require(time <= Int64.max - Self.handshakeMilliseconds)
            s.deadline = time + Self.handshakeMilliseconds
            let step1 = try external(s) { try noise.initiate(emptyPayload: Data()) }
            try require((1...Self.ciphertextBytes).contains(step1.count))
            try counters(s, complete: false); try checkTime(s)
            s.phase = .waiting // Reserve before wire: step2 may arrive synchronously.
            try external(s) { try port.sendHandshake(try RemoteHarnessSecureHandshake(connectionID: info.connectionID, targetDeviceID: info.remoteDeviceID, step: 1, bytes: step1), generation: binding.generation) }
        }
    }
    public func receiveHandshake(_ payload: RemoteHarnessSecureHandshake, generation: UInt64) throws {
        guard let s = session, s.binding.generation == generation else { return }
        try guarded(s, reason: .handshake) {
            try checkTime(s)
            guard let info = s.info else { throw RemoteHarnessSecureLinkError.failed }
            try require(s.phase == .waiting && payload.step == 2 && secureLinkEqual(payload.connectionID, info.connectionID) &&
                        secureLinkEqual(payload.targetDeviceID, info.localDeviceID) && (1...Self.ciphertextBytes).contains(payload.bytes.count))
            s.phase = .reading
            try counters(s, complete: false)
            let result = try external(s) { try s.noise!.readHandshake(payload.bytes) }
            try require(result.complete && result.response == nil && result.payload.isEmpty)
            try counters(s, complete: true); try checkTime(s)
            s.phase = .ready; s.deadline = nil // Observer may send immediately.
            try guarded(s, reason: .observer) { try external(s) { try observer.authenticated(binding: s.binding) } }
        }
    }
    public func send(_ data: Data, binding: RemoteHarnessBinding) throws {
        guard let s = session else { throw RemoteHarnessSecureLinkError.generation }
        guard secureLinkEqual(s.binding, binding) else { throw RemoteHarnessSecureLinkError.binding }
        try guarded(s, reason: .send) {
            try require(s.phase == .ready)
            try require(data.count <= RemoteHarnessFragments.messageBytes && s.reservedMessages < Self.queueMessages && data.count <= Self.queueBytes - s.reservedBytes)
            s.reservedMessages += 1; s.reservedBytes += data.count; s.queue.append(data)
            if !s.draining { try drain(s) }
        }
    }
    private func drain(_ s: Session) throws {
        s.draining = true
        while !s.queue.isEmpty {
            let message = s.queue.removeFirst() // Reservation includes this active batch.
            for frame in try s.fragments.encode(message, authenticatedGeneration: s.binding.generation) {
                try checkTime(s); try counters(s, complete: true)
                try require(s.sending < Self.maximumCounter)
                let counter = s.sending
                let ciphertext = try external(s) { try s.noise!.encrypt(frame.data) }
                try require((16...Self.ciphertextBytes).contains(ciphertext.count))
                s.sending = counter + 1; try counters(s, complete: true)
                let info = s.info!
                try external(s) { try port.sendRelay(try RemoteHarnessSecureRelay(connectionID: info.connectionID, targetDeviceID: info.remoteDeviceID, counter: counter, ciphertext: ciphertext), generation: s.binding.generation) }
            }
            s.reservedBytes -= message.count; s.reservedMessages -= 1
        }
        s.draining = false
    }
    public func receiveRelay(_ payload: RemoteHarnessSecureRelay, generation: UInt64) throws {
        guard let s = session, s.binding.generation == generation else { return }
        try guarded(s, reason: .receive) {
            try require(s.phase == .ready && !s.reading)
            s.reading = true // Reserve before clock/provider callbacks.
            try checkTime(s)
            let info = s.info!
            try require(secureLinkEqual(payload.connectionID, info.connectionID) && secureLinkEqual(payload.targetDeviceID, info.localDeviceID) &&
                        (0...Self.maximumCounter).contains(payload.counter) && payload.counter == s.receiving && s.receiving < Self.maximumCounter &&
                        (16...Self.ciphertextBytes).contains(payload.ciphertext.count))
            try counters(s, complete: true)
            let counter = s.receiving
            let plaintext = try external(s) { try s.noise!.decrypt(payload.ciphertext) }
            s.receiving = counter + 1; try counters(s, complete: true)
            let time = try now(s)
            let message = try s.fragments.decode(plaintext, authenticatedGeneration: s.binding.generation, monotonicMilliseconds: time)
            s.reading = false
            if let message { try guarded(s, reason: .observer) { try external(s) { try observer.receivedBusinessBytes(message.data, binding: s.binding) } } }
        }
    }
    /// Generation required: an old timer/close must never address a replacement.
    public func checkDeadlines(generation: UInt64) throws {
        guard let s = session, s.binding.generation == generation else { return }
        try guarded(s, reason: .deadline) { try checkTime(s) }
    }
    public func close(generation: UInt64) {
        guard let s = session, s.binding.generation == generation else { return }; retire(s, reason: .closed)
    }
    public func invalidate(binding: RemoteHarnessBinding) {
        guard let s = session, secureLinkEqual(s.binding, binding) else { return }; retire(s, reason: .closed)
    }
    /// Trusted adapter confirmation ONLY after this exact generation's channel and Host
    /// reservations are actually gone. Does not retry, reconnect or infer cleanup.
    public func confirmRetired(generation: UInt64) {
        if !retiring, teardownPending == generation { teardownPending = nil }
    }
    private func now(_ s: Session) throws -> Int64 {
        let value = try external(s) { clock.monotonicMilliseconds }
        try require(value >= 0 && (s.lastNow == nil || value >= s.lastNow!))
        s.lastNow = value; return value
    }
    private func checkTime(_ s: Session) throws {
        let value = try now(s)
        try require(s.deadline == nil || value < s.deadline!)
        try s.fragments.checkExpiry(authenticatedGeneration: s.binding.generation, monotonicMilliseconds: value)
    }
    private func counters(_ s: Session, complete: Bool) throws {
        let c = try external(s) { try s.noise!.counters() }
        try require(c.complete == complete && (0...Self.maximumCounter).contains(c.sending) && (0...Self.maximumCounter).contains(c.receiving) && c.sending == s.sending && c.receiving == s.receiving)
    }
    private func external<T>(_ s: Session, _ block: () throws -> T) throws -> T {
        let value = try block(); guard session === s else { throw RemoteHarnessSecureLinkError.generation }; return value
    }
    private func guarded(_ s: Session, reason: RemoteHarnessSecureRetirement, _ block: () throws -> Void) throws {
        do { try block() } catch {
            retire(s, reason: reason)
            // No injected diagnostic, cause, credential or payload is propagated.
            throw RemoteHarnessSecureLinkError.failed
        }
    }
    private func retire(_ s: Session, reason: RemoteHarnessSecureRetirement) {
        guard session === s else { return }
        session = nil; s.queue.removeAll(); s.reservedBytes = 0; s.reservedMessages = 0
        teardownPending = s.binding.generation; retiring = true
        try? s.fragments.retire(authenticatedGeneration: s.binding.generation)
        let noise = s.noise; s.noise = nil
        // Clear BEFORE callbacks. Remaining cleanup always addresses this exact generation,
        // even when shutdown creates a replacement synchronously.
        try? noise?.shutdown()
        do { try port.retire(generation: s.binding.generation); if teardownPending == s.binding.generation { teardownPending = nil } } catch {}
        retiring = false
        try? observer.retired(binding: s.binding, reason: reason)
    }
    private func require(_ value: Bool) throws { if !value { throw RemoteHarnessSecureLinkError.failed } }
}
