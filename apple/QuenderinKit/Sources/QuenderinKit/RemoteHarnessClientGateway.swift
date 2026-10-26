import Foundation

public struct RemoteHarnessClientHost: Identifiable, Equatable, NativeConnectionPrivateValue {
    public var id: String { deviceID }
    public let deviceID: String
    public let name: String
    public let platform: String
    public let membershipID: String
    public let online: Bool
    public let identityKey: String?
    init(_ value: RemoteHarnessJSON, descriptor: Bool) throws {
        let f = try value.fields(); deviceID = try f.text("deviceId"); try RemoteHarnessClientEncoding.deviceID(deviceID)
        guard try f.text("role") == "host" else { throw RemoteHarnessClientFailure.protocolMismatch }
        name = try f.text("name"); platform = try f.text("platform"); membershipID = try f.text("membershipId"); online = try f.required("online").booleanValue()
        guard name.utf8.count <= 128, !membershipID.isEmpty, membershipID.utf8.count <= 1024, platform.utf8.count <= 64 else { throw RemoteHarnessClientFailure.protocolMismatch }
        identityKey = try f["identityKey"]?.stringValue()
        if descriptor { guard let identityKey else { throw RemoteHarnessClientFailure.protocolMismatch }; _ = try RemoteHarnessClientEncoding.key(identityKey) }
    }
    func requireMatch(_ summary: Self) throws {
        guard deviceID.utf8.elementsEqual(summary.deviceID.utf8), membershipID.utf8.elementsEqual(summary.membershipID.utf8) else { throw RemoteHarnessClientFailure.protocolMismatch }
    }
    public var fingerprint: String? { guard let identityKey, let key = try? RemoteHarnessClientEncoding.key(identityKey) else { return nil }; return try? RemoteHarnessClientEncoding.digest(key) }
}

@MainActor final class RemoteHarnessClientSystemClock: RemoteHarnessClock {
    var nowEpochMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    var monotonicMilliseconds: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
}
@MainActor private final class RemoteHarnessClientSecureIdentity: RemoteHarnessSecureIdentity {
    let credential: RemoteHarnessClientCredential
    let peerKey: Data
    init(credential: RemoteHarnessClientCredential, peerKey: Data) { self.credential = credential; self.peerKey = peerKey }
}
@MainActor private final class RemoteHarnessClientNoiseFactory: RemoteHarnessSecureNoiseFactory {
    let backend: any RemoteHarnessCryptoBackend
    init(backend: any RemoteHarnessCryptoBackend) { self.backend = backend }
    func makeInitiator(enrollment: RemoteHarnessSecureEnrollment, info: RemoteHarnessSecureConnectionInfo, context: RemoteHarnessSecureNoiseContext) throws -> any RemoteHarnessSecureNoise {
        guard let identity = enrollment.identity as? RemoteHarnessClientSecureIdentity else { throw RemoteHarnessClientFailure.protocolMismatch }
        return try backend.initiator(privateSeed: identity.credential.privateSeed, peerPublicKey: identity.peerKey, info: info)
    }
}

/// The real relay/Noise/business path. All state and callbacks stay on MainActor.
/// Each async read, send failure, scheduler and continuation retains its generation.
@MainActor public final class RemoteHarnessClientGateway: RemoteHarnessSecurePacketPort, RemoteHarnessSecureObserver, NativeConnectionPrivateValue {
    private let makeSocket: @MainActor () -> any RemoteHarnessClientSocket
    private let backend: any RemoteHarnessCryptoBackend
    private let clock: any RemoteHarnessClock
    private let journal: any RemoteHarnessCommandJournal
    private lazy var link = RemoteHarnessSecureLink(port: self, factory: RemoteHarnessClientNoiseFactory(backend: backend), clock: clock, observer: self)
    private lazy var coordinator = RemoteHarnessCoordinator(port: link, clock: clock, journal: journal)
    private var socket: (any RemoteHarnessClientSocket)?
    private var receiveTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var generation: UInt64 = 0
    private var expectedBinding: RemoteHarnessBinding?
    private var identity: RemoteHarnessClientSecureIdentity?
    private var info: RemoteHarnessSecureConnectionInfo?
    private var phase = "closed"
    private var controlLimits = RemoteHarnessControlWireLimits.defaults
    private var setupDeadline: Int64 = 0
    private var lastFrame: Int64 = 0
    private var pingNonce: String?
    private var pingAt: Int64 = 0
    public var onDisconnected: (@MainActor (RemoteHarnessClientFailure) -> Void)?
    public var onStateChanged: (@MainActor () -> Void)?
    public private(set) var supportsCompanion = false
    public var supportsBotRead: Bool { coordinator.supportsBotRead }
    public var binding: RemoteHarnessBinding? { coordinator.binding }
    public var stopState: RemoteHarnessStopState { coordinator.stopState }
    public var approvals: [RemoteHarnessPendingApproval] { coordinator.pendingApprovalRequests }
    /// Apply the existing heartbeat/deadline policy immediately after suspension.
    /// A healthy generation and its active streams are kept intact.
    func reconcileForeground() {
        guard expectedBinding != nil, phase == "ready" else { return }
        tick(generation: generation)
    }
    public init(backend: any RemoteHarnessCryptoBackend, journal: any RemoteHarnessCommandJournal, clock: (any RemoteHarnessClock)? = nil, makeSocket: @escaping @MainActor () -> any RemoteHarnessClientSocket = { RemoteHarnessClientWebSocket() }) {
        self.backend = backend; self.journal = journal; self.clock = clock ?? RemoteHarnessClientSystemClock(); self.makeSocket = makeSocket
    }
    public func connect(credential: RemoteHarnessClientCredential, host: RemoteHarnessClientHost, workspaceID: String?, sessionID: String?) async throws {
        guard backend.isAvailable, let key = host.identityKey else { throw RemoteHarnessClientFailure.cryptoUnavailable }
        disconnect(); generation += 1; let current = generation
        let binding = try RemoteHarnessBinding(generation: current, hostID: host.deviceID, workspaceID: workspaceID, sessionID: sessionID, clientDeviceID: credential.deviceID)
        expectedBinding = binding; identity = RemoteHarnessClientSecureIdentity(credential: credential, peerKey: try RemoteHarnessClientEncoding.key(key))
        phase = "hello"; setupDeadline = clock.monotonicMilliseconds + 15_000; lastFrame = clock.monotonicMilliseconds
        let socket = makeSocket(); self.socket = socket
        try socket.start(origin: credential.origin)
        try sendControl("hello", .object(["role": .string("client"), "deviceId": .string(credential.deviceID), "accessToken": .string(credential.accessToken ?? ""), "protocols": .array([.integer(1)]), "capabilities": .array([.string("transport.relay")]), "clientVersion": .string("quenderin/0.4")]), generation: current)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                receiveTask = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let data = try await socket.receive()
                            guard let self, self.generation == current, self.expectedBinding != nil else { return }
                            try self.receive(data, generation: current)
                        }
                    } catch { self?.fail(.connection, generation: current) }
                }
                timer = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                        guard let self, self.generation == current, self.expectedBinding != nil else { return }
                        self.tick(generation: current)
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.fail(.connection, generation: current) } }
    }
    public func call(_ operation: RemoteHarnessOperation, commandID: String? = nil) async throws -> RemoteHarnessJSON? {
        let current = generation
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try coordinator.perform(operation, commandID: commandID) { [weak self] result in
                    guard let self, self.generation == current else { continuation.resume(throwing: RemoteHarnessClientFailure.connection); return }
                    self.onStateChanged?()
                    switch result {
                    case .response(let value): continuation.resume(returning: value)
                    case .outcomeUnknown: continuation.resume(throwing: RemoteHarnessClientFailure.unknownOutcome)
                    case .rejected: continuation.resume(throwing: RemoteHarnessClientFailure.protocolMismatch)
                    case .failed(let failure): continuation.resume(throwing: failure)
                    }
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    public func readBotRoster() async throws -> RemoteHarnessBotRoster {
        let current = generation
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try coordinator.readBotRoster { [weak self] result in
                    guard let self, self.generation == current else { continuation.resume(throwing: RemoteHarnessClientFailure.connection); return }
                    self.onStateChanged?()
                    switch result {
                    case .success(let roster): continuation.resume(returning: roster)
                    case .failure(let failure): continuation.resume(throwing: failure)
                    }
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
    public func follow(_ operation: (String) throws -> RemoteHarnessOperation, receive: @escaping RemoteHarnessCoordinator.StreamReceiver) throws {
        let current = generation, id = try coordinator.nextStreamID()
        try coordinator.perform(operation(id), onStream: { [weak self] update in
            guard let self, self.generation == current else { return }; receive(update); self.onStateChanged?()
        }) { [weak self] result in
            guard let self, self.generation == current else { return }
            if case .response = result { return }; self.fail(.connection, generation: current)
        }
    }
    public func disconnect() {
        supportsCompanion = false
        let old = expectedBinding; expectedBinding = nil; phase = "closed"
        ready?.resume(throwing: RemoteHarnessClientFailure.connection); ready = nil
        receiveTask?.cancel(); receiveTask = nil; timer?.cancel(); timer = nil
        coordinator.disconnect(); if let old { try? link.close(generation: old.generation) }
        socket?.close(); socket = nil; info = nil; identity = nil; pingNonce = nil
    }
    private func fail(_ failure: RemoteHarnessClientFailure, generation: UInt64) {
        guard self.generation == generation, expectedBinding != nil else { return }
        disconnect(); onDisconnected?(failure)
    }
    private func tick(generation: UInt64) {
        guard self.generation == generation else { return }
        let now = clock.monotonicMilliseconds
        if phase != "ready", now >= setupDeadline { fail(.timeout, generation: generation); return }
        if now - lastFrame >= 75_000 || (pingNonce != nil && now - pingAt >= 75_000) { fail(.timeout, generation: generation); return }
        do {
            if now - pingAt >= 25_000, pingNonce == nil {
                let nonce = UUID().uuidString; pingNonce = nonce; pingAt = now; try sendControl("ping", .object(["nonce": .string(nonce)]), generation: generation)
            }
            try link.checkDeadlines(generation: generation); coordinator.expireDeadlines(); onStateChanged?()
        } catch { fail(.connection, generation: generation) }
    }
    private func sendControl(_ type: String, _ payload: RemoteHarnessJSON, generation: UInt64) throws {
        let value = try RemoteHarnessJSON.object(["v": .integer(1), "id": .string(UUID().uuidString), "type": .string(type), "timestamp": .integer(clock.nowEpochMilliseconds), "payload": payload])
        guard value.data.count <= controlLimits.handshake else { throw RemoteHarnessClientFailure.limit }
        try enqueue(value.data, generation: generation)
    }
    private func enqueue(_ bytes: Data, generation: UInt64) throws {
        guard self.generation == generation, expectedBinding != nil, let socket else { throw RemoteHarnessClientFailure.connection }
        try socket.enqueue(bytes) { [weak self] in self?.fail(.connection, generation: generation) }
    }
    private func receive(_ bytes: Data, generation: UInt64) throws {
        guard self.generation == generation, let binding = expectedBinding else { return }
        let f = try RemoteHarnessJSON(data: bytes).fields(); try f.requireKeys(["v", "id", "type", "timestamp", "payload"])
        guard try f.required("v").integerValue() == 1, try f.required("timestamp").integerValue() > 0 else { throw RemoteHarnessClientFailure.protocolMismatch }
        _ = try f.text("id"); let type = try f.text("type")
        if type == "relay" || type == "secure.handshake" {
            let packet = try RemoteHarnessControlWire().decode(bytes, limits: controlLimits).packet
            switch packet { case .handshake(let p): try link.receiveHandshake(p, generation: generation); case .relay(let p): try link.receiveRelay(p, generation: generation) }
            lastFrame = clock.monotonicMilliseconds; return
        }
        guard bytes.count <= controlLimits.handshake else { throw RemoteHarnessClientFailure.limit }
        let p = try f.required("payload").fields()
        switch type {
        case "hello.ack":
            guard phase == "hello", try p.required("protocol").integerValue() == 1,
                  try p.required("heartbeatIntervalMs").integerValue() == 25_000 else { throw RemoteHarnessClientFailure.protocolMismatch }
            _ = try p.text("connectionSessionId") // Socket session is never the Noise connection ID.
            let caps = try p.required("capabilities").elements().map { try $0.stringValue() }
            guard caps == ["transport.relay"] else { throw RemoteHarnessClientFailure.protocolMismatch }
            controlLimits = try RemoteHarnessControlWireLimits(handshake: p.required("maxControlFrameBytes").integerValue(), relay: p.required("maxRelayFrameBytes").integerValue())
            phase = "accept"; try sendControl("connect.request", .object(["hostDeviceId": .string(binding.hostID), "preferredTransports": .array([.string("relay")])]), generation: generation)
        case "connect.accepted":
            guard phase == "accept", let identity else { throw RemoteHarnessClientFailure.protocolMismatch }
            let id = try p.text("connectionId")
            info = try RemoteHarnessSecureConnectionInfo(connectionID: id, localDeviceID: identity.credential.deviceID, remoteDeviceID: binding.hostID)
            phase = "noise"
            try sendControl("transport.selected", .object(["connectionId": .string(id), "targetDeviceId": .string(binding.hostID), "transport": .string("relay")]), generation: generation)
            try link.begin(binding: binding, enrollment: RemoteHarnessSecureEnrollment(client: .init(identity.credential.deviceID), host: .init(binding.hostID), identity: identity))
        case "ping": try sendControl("pong", .object(["nonce": .string(p.text("nonce"))]), generation: generation)
        case "pong":
            guard let pingNonce, try p.text("nonce").utf8.elementsEqual(pingNonce.utf8) else { throw RemoteHarnessClientFailure.protocolMismatch }; self.pingNonce = nil
        case "connect.rejected", "error": throw RemoteHarnessClientFailure.connection
        default: throw RemoteHarnessClientFailure.protocolMismatch
        }
        lastFrame = clock.monotonicMilliseconds
    }
    public func connectionInfo() throws -> RemoteHarnessSecureConnectionInfo { guard let info else { throw RemoteHarnessClientFailure.connection }; return info }
    public func sendHandshake(_ payload: RemoteHarnessSecureHandshake, generation: UInt64) throws {
        try enqueue(RemoteHarnessControlWire().encode(.handshake(payload), id: UUID().uuidString, timestamp: clock.nowEpochMilliseconds, limits: controlLimits), generation: generation)
    }
    public func sendRelay(_ payload: RemoteHarnessSecureRelay, generation: UInt64) throws {
        try enqueue(RemoteHarnessControlWire().encode(.relay(payload), id: UUID().uuidString, timestamp: clock.nowEpochMilliseconds, limits: controlLimits), generation: generation)
    }
    public func retire(generation: UInt64) throws { guard self.generation == generation else { return }; socket?.close() }
    public func authenticated(binding: RemoteHarnessBinding) throws {
        guard binding == expectedBinding else { throw RemoteHarnessClientFailure.connection }
        try coordinator.connect(authenticatedBinding: binding)
        try coordinator.perform(.describe()) { [weak self] result in
            guard let self, binding == self.expectedBinding else { return }
            guard case .response(let value?) = result,
                  let capabilities = try? value.fields().required("capabilities").elements().map({ try $0.stringValue() }) else { self.fail(.protocolMismatch, generation: binding.generation); return }
            self.supportsCompanion = capabilities.contains("quenderin.approvals.v1")
            self.phase = "ready"; self.ready?.resume(); self.ready = nil; self.onStateChanged?()
        }
    }
    public func receivedBusinessBytes(_ bytes: Data, binding: RemoteHarnessBinding) throws { try coordinator.receive(bytes, authenticatedBinding: binding); onStateChanged?() }
    public func retired(binding: RemoteHarnessBinding, reason: RemoteHarnessSecureRetirement) throws {
        guard binding == expectedBinding else { return }; fail(.connection, generation: binding.generation)
    }
}
