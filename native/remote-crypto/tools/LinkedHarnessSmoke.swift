import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Host-only integration: actual generated UniFFI/Rust Noise, production owners,
// and explicitly test-only enrollment, packet transport and in-memory journal.
// This does not establish account enrollment, network delivery or Host execution.
private enum LinkedFailure: Error { case failed }
private func require(_ valid: Bool) throws { if !valid { throw LinkedFailure.failed } }
private let connection = "linked-synthetic-connection"
private let client = "linked-synthetic-client"
private let host = "linked-synthetic-host"
private let session = "linked-synthetic-session"
private let command = "linked-synthetic-command"
private let generation: UInt64 = 1
private let prompt = "synthetic-linked-prompt-" + String(repeating: "p", count: 61_440)
private let padding = "synthetic-linked-padding-" + String(repeating: "s", count: 55_000)

@MainActor private final class TestIdentity: RemoteHarnessSecureIdentity {
    var privateKey: Data
    var peerPublicKey: Data
    init(privateKey: Data, peerPublicKey: Data) { self.privateKey = privateKey; self.peerPublicKey = peerPublicKey }
}

@MainActor private final class LinkedNoise: RemoteHarnessSecureNoise {
    private var handle: NoiseIkSession?
    private weak var released: NoiseIkSession?
    private(set) var shutdowns = 0
    private(set) var atShutdown: NoiseCounters?
    var disposed: Bool { handle == nil && released == nil }
    init(_ handle: NoiseIkSession) { self.handle = handle; released = handle }
    private func live() throws -> NoiseIkSession {
        guard let handle else { throw LinkedFailure.failed }; return handle
    }
    func initiate(emptyPayload: Data) throws -> Data {
        try require(emptyPayload.isEmpty)
        return try live().initiate()
    }
    func readHandshake(_ bytes: Data) throws -> RemoteHarnessSecureHandshakeResult {
        let result = try live().readHandshake(message: bytes)
        return try RemoteHarnessSecureHandshakeResult(complete: result.complete, payload: Data(), response: result.response)
    }
    func counters() throws -> RemoteHarnessSecureCounters {
        let counters = try live().counters()
        // Check the unsigned generated representation BEFORE any signed conversion.
        try require(counters.sending <= UInt64(RemoteHarnessSecureLink.maximumCounter) &&
                    counters.receiving <= UInt64(RemoteHarnessSecureLink.maximumCounter))
        return RemoteHarnessSecureCounters(complete: counters.complete, sending: Int64(counters.sending), receiving: Int64(counters.receiving))
    }
    func encrypt(_ plaintext: Data) throws -> Data { try live().encrypt(plaintext: plaintext) }
    func decrypt(_ ciphertext: Data) throws -> Data { try live().decrypt(ciphertext: ciphertext) }
    func shutdown() throws {
        guard let current = handle else { return }
        handle = nil; shutdowns += 1
        atShutdown = try? current.counters()
        // Clearing the last strong reference after Rust shutdown releases the
        // generated wrapper too; the weak reference independently checks this.
        try current.shutdown()
    }
}

private enum Mode: CaseIterable { case roundTrip, handshakeTamper, tagTamper }

@MainActor private final class LinkedRig: RemoteHarnessSecurePacketPort, RemoteHarnessSecureObserver,
    RemoteHarnessSecureNoiseFactory, RemoteHarnessCommandJournal, RemoteHarnessClock {
    private let mode: Mode
    private let identity: TestIdentity
    private var hostPrivate: Data
    private var responder: NoiseIkSession?
    private weak var releasedResponder: NoiseIkSession?
    private let peerFragments: RemoteHarnessFragments
    private let binding: RemoteHarnessBinding
    private var expectedInbound: [Data] = []
    private var adapter: LinkedNoise?
    private lazy var link = RemoteHarnessSecureLink(port: self, factory: self, clock: self, observer: self)
    private lazy var coordinator = RemoteHarnessCoordinator(port: link, clock: self, journal: self)
    private var factoryCalls = 0
    private var authenticatedCount = 0
    private var businessCount = 0
    private var outboundBusinessCount = 0
    private var outgoingFrames = 0
    private var incomingFrames = 0
    private var retiredCount = 0
    private var retiredPackets = 0
    private var responderAtRetirement: NoiseCounters?
    private var prepared: [RemoteHarnessJournalCommand] = []
    private var journalOutcomes: [RemoteHarnessJournalOutcome] = []
    private var outcomes: [RemoteHarnessCompletion] = []
    private var describeID: String?
    private var promptID: String?
    private var expectedOutgoingFrames = 0
    private var expectedIncomingFrames = 0
    private var tamperQueued = false
    var nowEpochMilliseconds: Int64 { 1 }
    var monotonicMilliseconds: Int64 { 0 }

    init(_ mode: Mode) throws {
        self.mode = mode
        var random = SystemRandomNumberGenerator()
        let clientPrivate = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        hostPrivate = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        identity = TestIdentity(privateKey: clientPrivate, peerPublicKey: try derivePublicKey(localPrivateKey: hostPrivate))
        let peer = try NoiseIkSession.create(role: .responder, localPrivateKey: hostPrivate,
            enrolledRemotePublicKey: derivePublicKey(localPrivateKey: clientPrivate),
            connectionId: connection, hostDeviceId: host, clientDeviceId: client)
        responder = peer; releasedResponder = peer
        peerFragments = try RemoteHarnessFragments(authenticatedGeneration: generation)
        binding = try RemoteHarnessBinding(generation: generation, hostID: host, workspaceID: "linked-synthetic-workspace", sessionID: session)
    }
    private func peer() throws -> NoiseIkSession {
        guard let responder else { throw LinkedFailure.failed }; return responder
    }
    private func fragmentsFor(_ bytes: Data) -> Int { max(1, (bytes.count + RemoteHarnessFragments.chunkBytes - 1) / RemoteHarnessFragments.chunkBytes) }
    private func promptOperation() throws -> RemoteHarnessOperation { try .prompt(commandID: command, sessionID: session, text: prompt) }

    func makeInitiator(enrollment: RemoteHarnessSecureEnrollment, info: RemoteHarnessSecureConnectionInfo,
                       context: RemoteHarnessSecureNoiseContext) throws -> any RemoteHarnessSecureNoise {
        try require(enrollment.identity === identity && info.connectionID == connection && info.localDeviceID == client && info.remoteDeviceID == host)
        try require(context.pattern == "Noise_IK_25519_ChaChaPoly_SHA256")
        try require(context.prologue == Data("DSH-REMOTE\0v=1\0connection=\(connection)\0host=\(host)\0client=\(client)".utf8))
        factoryCalls += 1
        let value = LinkedNoise(try NoiseIkSession.create(role: .initiator, localPrivateKey: identity.privateKey,
            enrolledRemotePublicKey: identity.peerPublicKey, connectionId: info.connectionID,
            hostDeviceId: info.remoteDeviceID, clientDeviceId: info.localDeviceID))
        adapter = value; return value
    }
    func connectionInfo() throws -> RemoteHarnessSecureConnectionInfo {
        try RemoteHarnessSecureConnectionInfo(connectionID: connection, localDeviceID: client, remoteDeviceID: host)
    }
    func sendHandshake(_ payload: RemoteHarnessSecureHandshake, generation: UInt64) throws {
        try require(generation == binding.generation && payload.step == 1 && payload.connectionID == connection && payload.targetDeviceID == host && payload.bytes.count == 96)
        let result = try peer().readHandshake(message: payload.bytes)
        guard var reply = result.response else { throw LinkedFailure.failed }
        try require(result.complete && reply.count == 48)
        if mode == .handshakeTamper { reply[reply.endIndex - 1] ^= 1 }
        // Intentionally synchronous, exercising readiness reservation before send.
        try link.receiveHandshake(try RemoteHarnessSecureHandshake(connectionID: connection, targetDeviceID: client, step: 2, bytes: reply), generation: generation)
    }
    func sendRelay(_ payload: RemoteHarnessSecureRelay, generation: UInt64) throws {
        try require(generation == binding.generation && payload.connectionID == connection && payload.targetDeviceID == host && payload.counter == Int64(outgoingFrames))
        try require(outgoingFrames < 8 && (16...RemoteHarnessSecureLink.ciphertextBytes).contains(payload.ciphertext.count))
        outgoingFrames += 1
        let bytes = try peerFragments.decode(peer().decrypt(ciphertext: payload.ciphertext), authenticatedGeneration: generation, monotonicMilliseconds: 0)?.data
        if mode == .tagTamper {
            try require(bytes == nil && peerFragments.assemblyCount == 1 && outgoingFrames == 1)
            try link.send(expectedPromptBytes("queued-synthetic-rpc"), binding: binding)
            try require(link.queuedMessageCount == 2 && link.queuedByteCount > 2 * RemoteHarnessFragments.chunkBytes)
            tamperQueued = true
            let fragment = try peerFragments.encode(describeResponse("synthetic-rpc"), authenticatedGeneration: generation)[0].data
            var bad = try peer().encrypt(plaintext: fragment)
            bad[bad.endIndex - 1] ^= 1
            try link.receiveRelay(try RemoteHarnessSecureRelay(connectionID: connection, targetDeviceID: client, counter: 0, ciphertext: bad), generation: generation)
            throw LinkedFailure.failed
        }
        guard let bytes else { return }
        try require(mode == .roundTrip && outboundBusinessCount < 2)
        let frame = try RemoteHarnessCodec().decode(bytes)
        guard case let .request(method, _) = frame.body else { throw LinkedFailure.failed }
        try require(frame.timestamp == 1)
        let expected: Data
        if outboundBusinessCount == 0 {
            try require(method == .describe && prepared.isEmpty)
            expected = try RemoteHarnessCodec().encodeRequest(id: frame.id, timestamp: 1, operation: .describe())
        } else {
            try require(prepared.count == 1 && prepared[0].rpcID == frame.id)
            expected = try expectedPromptBytes(frame.id)
        }
        try require(bytes == expected)
        expectedOutgoingFrames += fragmentsFor(expected)
        outboundBusinessCount += 1
        try sendResponse(outboundBusinessCount == 1 ? describeResponse(frame.id) : receiptResponse(frame.id))
    }
    private func expectedPromptBytes(_ id: String) throws -> Data {
        try RemoteHarnessCodec().encodeRequest(id: id, timestamp: 1, operation: promptOperation())
    }
    private func describeResponse(_ id: String) -> Data {
        Data(("{\"v\":1,\"id\":\"synthetic-describe-response\",\"type\":\"rpc.response\",\"timestamp\":1," +
            "\"payload\":{\"requestId\":\"\(id)\",\"result\":{\"capabilities\":[\"harness.remote.v3\"],\"syntheticPadding\":\"\(padding)\",\"syntheticNumber\":1.2300e+02}}}").utf8)
    }
    private func receiptResponse(_ id: String) -> Data {
        Data(("{\"v\":1,\"id\":\"synthetic-prompt-response\",\"type\":\"rpc.response\",\"timestamp\":1," +
            "\"payload\":{\"requestId\":\"\(id)\",\"result\":{\"ok\":true,\"value\":{\"syntheticReceipt\":\"received\"}}}}").utf8)
    }
    private func sendResponse(_ bytes: Data) throws {
        try require(expectedInbound.isEmpty)
        expectedInbound.append(bytes)
        let fragments = try peerFragments.encode(bytes, authenticatedGeneration: generation)
        try require(fragments.count == fragmentsFor(bytes))
        expectedIncomingFrames += fragments.count
        for fragment in fragments {
            try require(incomingFrames < 8)
            let counter = try peer().counters().sending
            try require(counter == UInt64(incomingFrames) && counter <= UInt64(RemoteHarnessSecureLink.maximumCounter))
            let ciphertext = try peer().encrypt(plaintext: fragment.data)
            incomingFrames += 1
            try link.receiveRelay(try RemoteHarnessSecureRelay(connectionID: connection, targetDeviceID: client, counter: Int64(counter), ciphertext: ciphertext), generation: generation)
        }
    }
    func authenticated(binding: RemoteHarnessBinding) throws {
        try require(binding == self.binding && link.isReady)
        authenticatedCount += 1
        try require(authenticatedCount == 1)
        if mode == .roundTrip {
            try coordinator.connect(authenticatedBinding: binding)
            describeID = try coordinator.perform(.describe()) { self.outcomes.append($0) }
        }
    }
    func receivedBusinessBytes(_ bytes: Data, binding: RemoteHarnessBinding) throws {
        try require(binding == self.binding && businessCount < 2 && !expectedInbound.isEmpty)
        try require(bytes == expectedInbound.removeFirst())
        businessCount += 1
        try coordinator.receive(bytes, authenticatedBinding: binding)
    }
    func retire(generation: UInt64) throws {
        try require(generation == binding.generation && retiredPackets == 0)
        retiredPackets += 1
        try peerFragments.retire(authenticatedGeneration: generation); expectedInbound.removeAll()
        responderAtRetirement = try? peer().counters()
        let current = responder; responder = nil
        try current?.shutdown()
    }
    func retired(binding: RemoteHarnessBinding, reason: RemoteHarnessSecureRetirement) throws {
        try require(binding == self.binding)
        retiredCount += 1
        coordinator.disconnect()
    }
    func persistBeforeDispatch(_ value: RemoteHarnessJournalCommand) throws {
        // Deliberately memory-only: proves preparation ordering, not durability.
        try require(prepared.isEmpty && value.commandID == command && value.binding == binding)
        prepared.append(value)
    }
    func recordOutcome(commandID: String, outcome: RemoteHarnessJournalOutcome) throws {
        try require(commandID == command && prepared.count == 1 && journalOutcomes.isEmpty)
        journalOutcomes.append(outcome)
    }
    private func gone() throws {
        try require(!link.isReady && link.activeGeneration == nil && link.queuedByteCount == 0 && link.queuedMessageCount == 0)
        try require(link.unconfirmedRetirementGeneration == nil && coordinator.pendingRPCCount == 0 && coordinator.activeStreamCount == 0)
        try require(retiredCount == 1 && retiredPackets == 1 && adapter?.shutdowns == 1 && adapter?.disposed == true && releasedResponder == nil)
        try require(peerFragments.isRetired && peerFragments.assemblyCount == 0 && peerFragments.declaredByteCount == 0 && expectedInbound.isEmpty)
    }
    private func begin() throws {
        let enrollment = try RemoteHarnessSecureEnrollment(client: .init(client), host: .init(host), identity: identity)
        try link.begin(binding: binding, enrollment: enrollment)
    }
    func run() throws {
        if mode == .handshakeTamper {
            try reject { try self.begin() }
            try gone(); try require(authenticatedCount == 0 && businessCount == 0 && outgoingFrames == 0)
            return
        }
        try begin()
        try require(factoryCalls == 1 && authenticatedCount == 1 && link.isReady)
        if mode == .tagTamper {
            try reject { try self.link.send(self.expectedPromptBytes("synthetic-rpc"), binding: self.binding) }
            try gone(); try require(tamperQueued && businessCount == 0 && outboundBusinessCount == 0)
            try require(adapter?.atShutdown == NoiseCounters(complete: true, sending: 1, receiving: 0))
            try require(responderAtRetirement == NoiseCounters(complete: true, sending: 1, receiving: 1))
            return
        }
        try require(outcomes.count == 1 && coordinator.pendingRPCCount == 0)
        guard case let .response(described?) = outcomes[0] else { throw LinkedFailure.failed }
        let describedFields = try described.fields()
        try require(describedFields.required("syntheticPadding").stringValue() == padding)
        try require(describedFields.required("syntheticNumber").data == Data("1.2300e+02".utf8))
        promptID = try coordinator.perform(promptOperation(), commandID: command) { self.outcomes.append($0) }
        try require(prepared.count == 1 && prepared[0].rpcID == promptID && journalOutcomes == [.responseReceived] && outcomes.count == 2)
        guard case let .response(receipt?) = outcomes[1] else { throw LinkedFailure.failed }
        try require(receipt.fields().required("syntheticReceipt").stringValue() == "received")
        try require(describeID != nil && promptID != nil && describeID != promptID)
        try require(outboundBusinessCount == 2 && businessCount == 2 && outgoingFrames == expectedOutgoingFrames && incomingFrames == expectedIncomingFrames)
        try require(outgoingFrames > 1 && incomingFrames > 1)
        guard let counters = try adapter?.counters() else { throw LinkedFailure.failed }
        try require(counters.complete && counters.sending == Int64(outgoingFrames) && counters.receiving == Int64(incomingFrames))
        try require(peer().counters() == NoiseCounters(complete: true, sending: UInt64(incomingFrames), receiving: UInt64(outgoingFrames)))
        try require(link.queuedByteCount == 0 && link.queuedMessageCount == 0 && coordinator.pendingRPCCount == 0 && expectedInbound.isEmpty)
        link.close(generation: generation); try gone()
    }
    func close() {
        link.close(generation: generation)
        try? responder?.shutdown(); responder = nil
        identity.privateKey.resetBytes(in: identity.privateKey.startIndex..<identity.privateKey.endIndex)
        identity.peerPublicKey.resetBytes(in: identity.peerPublicKey.startIndex..<identity.peerPublicKey.endIndex)
        hostPrivate.resetBytes(in: hostPrivate.startIndex..<hostPrivate.endIndex)
    }
}

@MainActor private func reject(_ action: () throws -> Void) throws {
    do { try action() } catch is RemoteHarnessSecureLinkError { return }
    throw LinkedFailure.failed
}

@main private struct LinkedHarnessSmoke {
    @MainActor static func main() {
        do {
            for mode in Mode.allCases {
                let rig = try LinkedRig(mode)
                defer { rig.close() }
                try rig.run()
            }
            print("NATIVE_LINKED_HARNESS_PASS swift")
        } catch {
            FileHandle.standardError.write(Data("Native linked Swift harness failed.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
