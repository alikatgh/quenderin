import Foundation
import XCTest
@testable import QuenderinKit

private enum SecureFixtureError: Error { case assertion, injected }
private func secureRequire(_ value: Bool) throws { if !value { throw SecureFixtureError.assertion } }
private func secureReject(_ block: () throws -> Void) throws {
    var failed = false
    do { try block() } catch {
        failed = error is RemoteHarnessSecureLinkError
        try secureRequire(!String(describing: error).contains("PRIVATE"))
    }
    try secureRequire(failed)
}
@MainActor private final class SecureClock: RemoteHarnessClock {
    var now: Int64 = 0
    var onRead: (() -> Void)?
    var nowEpochMilliseconds: Int64 { 1 }
    var monotonicMilliseconds: Int64 { onRead?(); return now }
}
/// Deliberately NOT cryptography: deterministic plaintext plus a 16-byte marker.
@MainActor private final class SecureNoise: RemoteHarnessSecureNoise {
    var complete = false, decryptThrows = false, encryptOversize = false
    var sending: Int64 = 0, receiving: Int64 = 0, sendAdvance: Int64 = 1, receiveAdvance: Int64 = 1
    var resultPayload = Data()
    var resultResponse: Data?
    var onShutdown: (() throws -> Void)?, onEncrypt: (() throws -> Void)?, onDecrypt: (() throws -> Void)?, onCounters: (() throws -> Void)?
    var shutdowns = 0, handshakeReads = 0
    var encrypted: [Data] = []
    func initiate(emptyPayload: Data) throws -> Data { try secureRequire(emptyPayload.isEmpty); return Data([0x11]) }
    func readHandshake(_ bytes: Data) throws -> RemoteHarnessSecureHandshakeResult {
        handshakeReads += 1
        try secureRequire(bytes == Data([0x22])); complete = true
        return try RemoteHarnessSecureHandshakeResult(complete: true, payload: resultPayload, response: resultResponse)
    }
    func counters() throws -> RemoteHarnessSecureCounters {
        try onCounters?(); return RemoteHarnessSecureCounters(complete: complete, sending: sending, receiving: receiving)
    }
    func encrypt(_ plaintext: Data) throws -> Data {
        encrypted.append(plaintext); sending += sendAdvance; try onEncrypt?()
        return encryptOversize ? Data(repeating: 0, count: 65_536) : plaintext + Data(repeating: 0, count: 16)
    }
    func decrypt(_ ciphertext: Data) throws -> Data {
        try onDecrypt?(); if decryptThrows { throw SecureFixtureError.injected }
        receiving += receiveAdvance; return Data(ciphertext.dropLast(16))
    }
    func shutdown() throws { shutdowns += 1; try onShutdown?() }
}
@MainActor private final class SecureIdentity: RemoteHarnessSecureIdentity {}
@MainActor private final class SecureRig: RemoteHarnessSecurePacketPort, RemoteHarnessSecureNoiseFactory, RemoteHarnessSecureObserver {
    let clock = SecureClock()
    let enrollment: RemoteHarnessSecureEnrollment
    var info: RemoteHarnessSecureConnectionInfo
    var noises: [SecureNoise] = [], sent: [RemoteHarnessSecureRelay] = []
    var retired: [UInt64] = [], noticed: [UInt64] = [], received: [Data] = []
    var factoryCalls = 0, handshakeSends = 0
    var expectedPrologue = "DSH-REMOTE\0v=1\0connection=connection-a\0host=host-a\0client=client-a"
    var onFactory: (() throws -> Void)?, onSend: (() throws -> Void)?, onReceive: (() throws -> Void)?, onRetire: (() throws -> Void)?, onInfo: (() throws -> Void)?
    var onNoise: ((SecureNoise) throws -> Void)?
    var onHandshake: ((UInt64) throws -> Void)?, onAuth: ((RemoteHarnessBinding) throws -> Void)?
    lazy var link = RemoteHarnessSecureLink(port: self, factory: self, clock: clock, observer: self)
    init() throws {
        enrollment = RemoteHarnessSecureEnrollment(client: try RemoteHarnessSecureClientID("client-a"), host: try RemoteHarnessSecureHostID("host-a"), identity: SecureIdentity())
        info = try RemoteHarnessSecureConnectionInfo(connectionID: "connection-a", localDeviceID: "client-a", remoteDeviceID: "host-a")
    }
    var noise: SecureNoise { noises.last! }
    func binding(_ generation: UInt64 = 1) throws -> RemoteHarnessBinding {
        try RemoteHarnessBinding(generation: generation, hostID: "host-a", workspaceID: "workspace-a", sessionID: "session-a")
    }
    func begin(_ generation: UInt64 = 1) throws { try link.begin(binding: binding(generation), enrollment: enrollment) }
    func ready(_ generation: UInt64 = 1) throws { try begin(generation); try step2(generation); try secureRequire(link.isReady) }
    func step2(_ generation: UInt64 = 1, step: Int = 2, target: String = "client-a") throws {
        try link.receiveHandshake(try RemoteHarnessSecureHandshake(connectionID: "connection-a", targetDeviceID: target, step: step, bytes: Data([0x22])), generation: generation)
    }
    func relay(_ plaintext: Data, counter: Int64? = nil, generation: UInt64 = 1, target: String = "client-a") throws {
        try link.receiveRelay(try RemoteHarnessSecureRelay(connectionID: "connection-a", targetDeviceID: target, counter: counter ?? noise.receiving, ciphertext: plaintext + Data(repeating: 0, count: 16)), generation: generation)
    }
    func connectionInfo() throws -> RemoteHarnessSecureConnectionInfo { try onInfo?(); return info }
    func makeInitiator(enrollment: RemoteHarnessSecureEnrollment, info: RemoteHarnessSecureConnectionInfo, context: RemoteHarnessSecureNoiseContext) throws -> any RemoteHarnessSecureNoise {
        factoryCalls += 1
        try secureRequire(context.pattern == "Noise_IK_25519_ChaChaPoly_SHA256")
        try secureRequire(context.prologue == Data(expectedPrologue.utf8))
        let noise = SecureNoise(); noises.append(noise); try onNoise?(noise); try onFactory?(); return noise
    }
    func sendHandshake(_ payload: RemoteHarnessSecureHandshake, generation: UInt64) throws {
        handshakeSends += 1
        try secureRequire(payload.step == 1 && payload.targetDeviceID == "host-a" && payload.bytes == Data([0x11]))
        try onHandshake?(generation)
    }
    func sendRelay(_ payload: RemoteHarnessSecureRelay, generation: UInt64) throws { sent.append(payload); try onSend?() }
    func retire(generation: UInt64) throws { retired.append(generation); try onRetire?() }
    func authenticated(binding: RemoteHarnessBinding) throws { noticed.append(binding.generation); try onAuth?(binding) }
    func receivedBusinessBytes(_ bytes: Data, binding: RemoteHarnessBinding) throws { received.append(bytes); try onReceive?() }
    func retired(binding: RemoteHarnessBinding, reason: RemoteHarnessSecureRetirement) throws {}
    func gone() throws { try secureRequire(link.activeGeneration == nil && !link.isReady && link.queuedByteCount == 0 && link.queuedMessageCount == 0) }
}
@MainActor private final class SecureJournal: RemoteHarnessCommandJournal {
    var prepared: [RemoteHarnessJournalCommand] = []
    var outcomes: [RemoteHarnessJournalOutcome] = []
    func persistBeforeDispatch(_ command: RemoteHarnessJournalCommand) throws { prepared.append(command) }
    func recordOutcome(commandID: String, outcome: RemoteHarnessJournalOutcome) throws { outcomes.append(outcome) }
}

@MainActor final class RemoteHarnessSecureLinkTests: XCTestCase {
    private struct Step: Decodable { let action: String }
    private struct Fixture: Decodable { let id: String; let steps: [Step] }
    private struct Document: Decodable { let schemaVersion: Int; let upstreamRevision: String; let cases: [Fixture] }
    private func scenario(_ action: String) throws {
        switch action {
        case "synchronous-step2-auth-send":
            let f = try SecureRig(); f.onHandshake = { try f.step2($0) }
            f.onAuth = { try secureRequire(f.link.isReady); try f.link.send(Data([97]), binding: $0) }
            try f.begin(); try secureRequire(f.noticed == [1] && f.sent.count == 1 && f.sent[0].counter == 0 && f.noise.sending == 1)
        case "reentrant-fragment-order":
            let f = try SecureRig(); try f.ready(); var once = false
            f.onSend = { if !once { once = true; try f.link.send(Data([98]), binding: f.binding()) } }
            try f.link.send(Data(repeating: 97, count: 49_153), binding: f.binding())
            try secureRequire(f.sent.map(\.counter) == [0, 1, 2] && f.noise.encrypted.map(\.count) == [49_169, 18, 1])
            for p in f.sent { try f.relay(Data(p.ciphertext.dropLast(16))) }
            try secureRequire(f.received == [Data(repeating: 97, count: 49_153), Data([98])] && f.link.queuedMessageCount == 0)
        case "partial-send-throws":
            let f = try SecureRig(); try f.ready(); f.onSend = { throw SecureFixtureError.injected }
            try secureReject { try f.link.send(Data(repeating: 97, count: 49_153), binding: f.binding()) }; try f.gone()
            try secureRequire(f.sent.count == 1 && f.retired == [1] && f.noise.shutdowns == 1)
        case "decrypt-fault-retires":
            let f = try SecureRig(); try f.ready(); f.noise.decryptThrows = true
            try secureReject { try f.relay(Data([97])) }; try f.gone(); try f.relay(Data([98]))
            try secureRequire(f.received.isEmpty && f.noise.shutdowns == 1 && f.retired == [1])
        case "handshake-deadline-boundary":
            let valid = try SecureRig(); try valid.begin(); valid.clock.now = 9_999; try valid.step2(); try secureRequire(valid.link.isReady)
            let expired = try SecureRig(); try expired.begin(); expired.clock.now = 10_000
            try secureReject { try expired.step2() }; try expired.gone(); try secureRequire(expired.noticed.isEmpty)
            let idle = try SecureRig(); try idle.begin(); idle.clock.now = 10_000
            try secureReject { try idle.link.checkDeadlines(generation: 1) }; try idle.gone()
        case "identity-preflight":
            let f = try SecureRig(); f.info = try RemoteHarnessSecureConnectionInfo(connectionID: "connection-a", localDeviceID: "client-a", remoteDeviceID: "wrong-host")
            try secureReject { try f.begin() }; try f.gone(); try secureRequire(f.factoryCalls == 0 && f.handshakeSends == 0)
            let other = try SecureRig()
            try secureReject { try other.link.begin(binding: RemoteHarnessBinding(generation: 1, hostID: "wrong-host"), enrollment: other.enrollment) }
            try secureRequire(other.factoryCalls == 0)
        case "identifier-validation":
            for bad in ["", "a\0b", String(repeating: "a", count: 1_025), String(repeating: "界", count: 342)] {
                try secureReject { _ = try RemoteHarnessSecureClientID(bad) }; try secureReject { _ = try RemoteHarnessSecureHostID(bad) }
                try secureReject { _ = try RemoteHarnessSecureConnectionInfo(connectionID: bad, localDeviceID: "client", remoteDeviceID: "host") }
            }
            try secureRequire(try RemoteHarnessSecureClientID(String(repeating: "界", count: 341)).value.utf8.count == 1_023)
            let oversized = Data(repeating: 0, count: 65_536)
            try secureReject { _ = try RemoteHarnessSecureHandshake(connectionID: "c", targetDeviceID: "t", step: 2, bytes: oversized) }
            try secureReject { _ = try RemoteHarnessSecureRelay(connectionID: "c", targetDeviceID: "t", counter: 0, ciphertext: oversized) }
            try secureReject { _ = try RemoteHarnessSecureHandshakeResult(complete: true, payload: oversized) }
            try secureReject { _ = try RemoteHarnessSecureHandshakeResult(complete: true, payload: Data(), response: oversized) }
        case "handshake-step-target-duplicate":
            for step in [1, 3] { let f = try SecureRig(); try f.begin(); try secureReject { try f.step2(step: step) }; try f.gone() }
            let f = try SecureRig(); try f.begin(); try secureReject { try f.step2(target: "host-a") }; try f.gone()
            let duplicate = try SecureRig(); try duplicate.ready(); try secureReject { try duplicate.step2() }; try duplicate.gone()
        case "packet-binding-counter":
            for counter: Int64 in [-1, 1, 9_007_199_254_740_992] {
                let f = try SecureRig(); try f.ready(); try secureReject { try f.relay(Data([97]), counter: counter) }; try f.gone(); try secureRequire(f.received.isEmpty)
            }
            let f = try SecureRig(); try f.ready(); try secureReject { try f.relay(Data([97]), target: "host-a") }; try f.gone()
        case "provider-counter-state":
            for advance: Int64 in [0, 2, -1] {
                let f = try SecureRig(); try f.ready(); f.noise.sendAdvance = advance
                try secureReject { try f.link.send(Data([97]), binding: f.binding()) }; try f.gone(); try secureRequire(f.sent.isEmpty)
                let g = try SecureRig(); try g.ready(); g.noise.receiveAdvance = advance
                try secureReject { try g.relay(Data([97])) }; try g.gone(); try secureRequire(g.received.isEmpty)
            }
            for counter: Int64 in [-1, 9_007_199_254_740_992] {
                let f = try SecureRig(); f.onNoise = { $0.sending = counter }; try secureReject { try f.begin() }; try f.gone()
            }
            let f = try SecureRig(); try f.ready(); f.noise.complete = false
            try secureReject { try f.link.send(Data([97]), binding: f.binding()) }; try f.gone()
            let preRead = try SecureRig(); try preRead.begin(); preRead.noise.complete = true
            try secureReject { try preRead.step2() }; try preRead.gone(); try secureRequire(preRead.noise.handshakeReads == 0)
        case "handshake-payload-response":
            for response in [false, true] {
                let f = try SecureRig(); f.onNoise = { if response { $0.resultResponse = Data() } else { $0.resultPayload = Data([97]) } }
                try f.begin(); try secureReject { try f.step2() }; try f.gone(); try secureRequire(f.noticed.isEmpty)
            }
        case "fragment-expiry-idle":
            let frames = try RemoteHarnessFragments(authenticatedGeneration: 1).encode(Data(repeating: 97, count: 49_153), authenticatedGeneration: 1)
            let f = try SecureRig(); try f.ready(); try f.relay(frames[0].data); f.clock.now = 119_999; try f.link.checkDeadlines(generation: 1)
            try secureRequire(f.received.isEmpty); f.clock.now = 120_000
            try secureReject { try f.link.checkDeadlines(generation: 1) }; try f.gone()
        case "fragment-error-retires":
            let f = try SecureRig(); try f.ready(); try secureReject { try f.relay(Data([0x44, 0x53, 0x48, 0x46])) }; try f.gone()
            try secureRequire(f.received.isEmpty && f.retired == [1])
        case "queue-message-budget":
            let f = try SecureRig(); try f.ready(); var once = false
            f.onSend = { if !once { once = true
                for _ in 0..<255 { try f.link.send(Data(), binding: f.binding()) }
                try secureRequire(f.link.queuedMessageCount == 256)
                try secureReject { try f.link.send(Data(), binding: f.binding()) }
            } }
            try secureReject { try f.link.send(Data([97]), binding: f.binding()) }; try f.gone(); try secureRequire(f.sent.count == 1)
        case "queue-byte-budget":
            let f = try SecureRig(); try f.ready(); var once = false
            f.onSend = { if !once { once = true; try f.link.send(Data(repeating: 98, count: 4_194_304), binding: f.binding())
                try secureRequire(f.link.queuedByteCount == 8_388_608); try secureReject { try f.link.send(Data([99]), binding: f.binding()) }
            } }
            try secureReject { try f.link.send(Data(repeating: 97, count: 4_194_304), binding: f.binding()) }; try f.gone(); try secureRequire(f.sent.count == 1)
        case "stale-callbacks-after-replacement":
            let f = try SecureRig(); try f.ready(); try f.ready(2)
            try f.step2(1); try f.relay(Data([97]), generation: 1); try f.link.checkDeadlines(generation: 1); f.link.close(generation: 1); f.link.invalidate(binding: try f.binding())
            try secureReject { try f.link.send(Data([97]), binding: f.binding()) }; try secureReject { try f.begin(1) }
            try secureRequire(f.link.activeGeneration == 2 && f.link.isReady && f.received.isEmpty && f.retired == [1])
        case "replacement-during-factory":
            let f = try SecureRig(); var once = false; f.onFactory = { if !once { once = true; try f.ready(2) } }
            try secureReject { try f.begin() }; try secureRequire(f.link.activeGeneration == 2 && f.link.isReady && f.noises[0].shutdowns == 1 && f.retired == [1])
        case "replacement-during-clock-info":
            for useClock in [false, true] {
                let f = try SecureRig(); var once = false
                if useClock { f.clock.onRead = { if !once { once = true; try? f.ready(2) } } }
                else { f.onInfo = { if !once { once = true; try f.ready(2) } } }
                try secureReject { try f.begin() }; try secureRequire(f.link.activeGeneration == 2 && f.link.isReady && f.retired == [1])
            }
        case "replacement-during-shutdown":
            let f = try SecureRig(); try f.ready(); f.noise.onShutdown = { try secureReject { try f.begin(3) } }
            try f.ready(2); try secureRequire(f.link.activeGeneration == 2 && f.link.isReady && f.retired == [1])
            try secureReject { try f.begin(2) }; try secureRequire(f.link.activeGeneration == 2)
        case "replacement-during-observers":
            let f = try SecureRig(); f.onAuth = { if $0.generation == 1 { try f.ready(2) } }
            try secureReject { try f.ready() }; try secureRequire(f.link.activeGeneration == 2 && f.link.isReady)
            let g = try SecureRig(); try g.ready(); g.onReceive = { try g.ready(2) }
            try secureReject { try g.relay(Data([97])) }; try secureRequire(g.link.activeGeneration == 2 && g.link.isReady && g.received.count == 1)
        case "replacement-during-encrypt-send":
            for inNoise in [false, true] {
                let f = try SecureRig(); try f.ready()
                if inNoise { f.noise.onEncrypt = { try f.ready(2) } } else { f.onSend = { f.onSend = nil; try f.ready(2) } }
                try secureReject { try f.link.send(Data(repeating: 97, count: 49_153), binding: f.binding()) }
                try secureRequire(f.link.activeGeneration == 2 && f.link.isReady && f.sent.count == (inNoise ? 0 : 1))
            }
        case "observer-and-cleanup-failure":
            let f = try SecureRig(); f.onAuth = { _ in throw SecureFixtureError.injected }; try f.begin(); try secureReject { try f.step2() }; try f.gone()
            let g = try SecureRig(); try g.ready(); g.onReceive = { throw SecureFixtureError.injected }; try secureReject { try g.relay(Data([97])) }; try g.gone()
            let h = try SecureRig(); try h.ready(); h.noise.onShutdown = { throw SecureFixtureError.injected }; h.onRetire = { throw SecureFixtureError.injected }
            h.link.close(generation: 1); h.link.close(generation: 1); try h.gone(); try secureRequire(h.retired == [1] && h.noise.shutdowns == 1)
            try secureRequire(h.link.unconfirmedRetirementGeneration == 1); try secureReject { try h.begin(2) }
            h.link.confirmRetired(generation: 2); try secureRequire(h.link.unconfirmedRetirementGeneration == 1)
            h.link.confirmRetired(generation: 1); h.onRetire = nil; try h.ready(2); try secureRequire(h.link.isReady)
            h.onRetire = { throw SecureFixtureError.injected }; h.link.close(generation: 2)
            h.link.confirmRetired(generation: 1); try secureRequire(h.link.unconfirmedRetirementGeneration == 2)
            try secureReject { try h.begin(3) }
            let replacement = try SecureRig(); try replacement.ready()
            replacement.onRetire = { try secureReject { try replacement.begin(3) }; throw SecureFixtureError.injected }
            try secureReject { try replacement.begin(2) }; try replacement.gone()
            try secureRequire(replacement.link.unconfirmedRetirementGeneration == 1 && replacement.factoryCalls == 1)
            replacement.link.confirmRetired(generation: 1); replacement.onRetire = nil
            try secureReject { try replacement.begin(2) }; try replacement.ready(3); try secureRequire(replacement.link.isReady)
        case "clock-regression-overflow":
            let f = try SecureRig(); f.clock.now = 10; try f.ready(); f.clock.now = 9
            try secureReject { try f.link.checkDeadlines(generation: 1) }; try f.gone()
            let g = try SecureRig(); g.clock.now = Int64.max - 9_999
            try secureReject { try g.begin() }; try g.gone(); try secureRequire(g.handshakeSends == 0 && g.noise.shutdowns == 1)
        case "ciphertext-size-and-reentrant-decrypt":
            let f = try SecureRig(); try f.ready(); f.noise.encryptOversize = true
            try secureReject { try f.link.send(Data([97]), binding: f.binding()) }; try f.gone(); try secureRequire(f.sent.isEmpty)
            let g = try SecureRig(); try g.ready(); g.noise.onDecrypt = { g.noise.onDecrypt = nil; try g.relay(Data([98])) }
            try secureReject { try g.relay(Data([97])) }; try g.gone(); try secureRequire(g.received.isEmpty)
        case "privacy-and-byte-ownership":
            let f = try SecureRig(); try f.ready(); var bytes = Data([97])
            let p = try RemoteHarnessSecureRelay(connectionID: "PRIVATE", targetDeviceID: "PRIVATE", counter: 0, ciphertext: bytes)
            bytes[0] = 98; var exported = p.ciphertext; exported[0] = 99; try secureRequire(p.ciphertext == Data([97]))
            let values: [Any] = [f.link, f.info, f.enrollment, f.enrollment.client, f.enrollment.host, p,
                try RemoteHarnessSecureHandshake(connectionID: "PRIVATE", targetDeviceID: "PRIVATE", step: 2, bytes: bytes),
                try RemoteHarnessSecureHandshakeResult(complete: true, payload: bytes)]
            for value in values {
                try secureRequire(String(describing: value).contains("redacted") && !String(reflecting: value).contains("PRIVATE"))
                try secureRequire(Mirror(reflecting: value).children.isEmpty)
            }
        case "coordinator-roundtrip-unknown":
            let f = try SecureRig(), journal = SecureJournal()
            let coordinator = RemoteHarnessCoordinator(port: f.link, clock: f.clock, journal: journal)
            var outcomes: [RemoteHarnessCompletion] = []
            f.onAuth = { try coordinator.connect(authenticatedBinding: $0); try coordinator.perform(.describe()) { outcomes.append($0) } }
            f.onReceive = { try coordinator.receive(f.received.last!, authenticatedBinding: f.binding()) }
            try f.ready()
            let describe = try RemoteHarnessCodec().decode(f.noise.encrypted[0])
            let response = "{\"v\":1,\"id\":\"host-response\",\"type\":\"rpc.response\",\"timestamp\":1,\"payload\":{\"requestId\":\"\(describe.id)\",\"result\":{\"capabilities\":[\"harness.remote.v3\"]}}}"
            try f.relay(Data(response.utf8)); try secureRequire(outcomes.count == 1)
            f.onSend = { throw SecureFixtureError.injected }
            try coordinator.perform(.prompt(commandID: "command-a", sessionID: "session-a", text: "synthetic"), commandID: "command-a") { outcomes.append($0) }
            try secureRequire(journal.prepared.count == 1 && outcomes.last == .outcomeUnknown && coordinator.pendingRPCCount == 0)
            try f.gone(); try secureRequire(f.sent.count == 2)
        case "opaque-unicode-identities":
            let f = try SecureRig(); f.info = try RemoteHarnessSecureConnectionInfo(connectionID: "connection-a", localDeviceID: "clie\u{301}nt", remoteDeviceID: "host-a")
            let enrolled = RemoteHarnessSecureEnrollment(client: try RemoteHarnessSecureClientID("cli\u{e9}nt"), host: f.enrollment.host, identity: f.enrollment.identity)
            try secureReject { try f.link.begin(binding: f.binding(), enrollment: enrolled) }; try secureRequire(f.factoryCalls == 0)
            for targetMismatch in [false, true] {
                let g = try SecureRig(); g.info = try RemoteHarnessSecureConnectionInfo(connectionID: "caf\u{e9}", localDeviceID: "cli\u{e9}nt", remoteDeviceID: "host-a")
                g.expectedPrologue = "DSH-REMOTE\0v=1\0connection=caf\u{e9}\0host=host-a\0client=cli\u{e9}nt"
                let enrollment = RemoteHarnessSecureEnrollment(client: try RemoteHarnessSecureClientID("cli\u{e9}nt"), host: g.enrollment.host, identity: g.enrollment.identity)
                try g.link.begin(binding: g.binding(), enrollment: enrollment)
                try g.link.receiveHandshake(RemoteHarnessSecureHandshake(connectionID: "caf\u{e9}", targetDeviceID: "cli\u{e9}nt", step: 2, bytes: Data([0x22])), generation: 1)
                try secureRequire(g.link.isReady)
                try secureReject { try g.link.receiveRelay(RemoteHarnessSecureRelay(connectionID: targetMismatch ? "caf\u{e9}" : "cafe\u{301}", targetDeviceID: targetMismatch ? "clie\u{301}nt" : "cli\u{e9}nt", counter: 0, ciphertext: Data(repeating: 0, count: 17)), generation: 1) }
                try g.gone(); try secureRequire(g.received.isEmpty)
            }
            let binding = try SecureRig()
            let exact = try RemoteHarnessBinding(generation: 1, hostID: "host-a", workspaceID: "workspace-a", sessionID: "caf\u{e9}")
            try binding.link.begin(binding: exact, enrollment: binding.enrollment); try binding.step2()
            let different = try RemoteHarnessBinding(generation: 1, hostID: "host-a", workspaceID: "workspace-a", sessionID: "cafe\u{301}")
            try secureReject { try binding.link.send(Data([97]), binding: different) }; binding.link.invalidate(binding: different)
            try secureRequire(binding.link.isReady && binding.retired.isEmpty)
        case "serialized-owner-confinement":
            // Swift statically confines every state entry to MainActor; calls here prove
            // the actual actor context and synchronous coordinator callback path.
            MainActor.preconditionIsolated()
            let f = try SecureRig(); f.onHandshake = { try f.step2($0) }
            f.onAuth = { try f.link.send(Data([97]), binding: $0) }
            try f.begin(); try f.relay(Data([98]))
            try secureRequire(f.link.isReady && f.sent.count == 1 && f.received == [Data([98])])
        default: throw SecureFixtureError.assertion
        }
    }
    func testSharedSyntheticSecureLinkFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: root.appendingPathComponent("shared/remote-harness-secure-link-fixtures.json")))
        try secureRequire(document.schemaVersion == 1 && document.upstreamRevision == "9a60e783ec1ceaff6116b0462a2863f07f602a55")
        var seen: Set<String> = []
        for fixture in document.cases {
            try secureRequire(seen.insert(fixture.id).inserted && !fixture.steps.isEmpty)
            do { for step in fixture.steps { try scenario(step.action) } }
            catch { XCTFail("Remote Harness secure-link fixture failed: \(fixture.id)"); throw SecureFixtureError.assertion }
            print("REMOTE_HARNESS_SECURE_LINK_FIXTURE_PASS \(fixture.id)")
        }
        try secureRequire(!seen.isEmpty)
    }
}
