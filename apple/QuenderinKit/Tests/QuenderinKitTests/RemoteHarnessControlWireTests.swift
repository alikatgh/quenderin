import Foundation
import XCTest
@testable import QuenderinKit

final class RemoteHarnessControlWireTests: XCTestCase {
    private enum Mismatch: Error { case fixture }
    private struct Config: Decodable { let handshake: Int64?; let relay: Int64? }
    private struct Wire: Decodable {
        let text: String?; let prefix: String?; let token: String?; let count: Int?
        let suffix: String?; let padTo: Int?; let appendHex: String?
    }
    private struct Packet: Decodable {
        let id: String; let timestamp: Int64; let type: String
        let connectionId: String; let targetDeviceId: String
        let step: Int?; let counter: Int64?; let hex: String?; let count: Int?; let byte: UInt8?; let base64: String?
    }
    private struct Step: Decodable {
        let action: String; let config: Config?; let wire: Wire?; let packet: Packet?; let expected: Packet?
        let reject: Bool?; let expectedHandshake: Int?; let expectedRelay: Int?
    }
    private struct Fixture: Decodable { let id: String; let steps: [Step] }
    private struct Document: Decodable { let schemaVersion: Int; let upstreamRevision: String; let origin: String; let cases: [Fixture] }
    private func require(_ value: Bool) throws { if !value { throw Mismatch.fixture } }
    private func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private func hex(_ source: String) throws -> Data {
        let chars = Array(source); try require(chars.count % 2 == 0)
        var result = Data()
        for offset in stride(from: 0, to: chars.count, by: 2) {
            result.append(try XCTUnwrap(UInt8(String(chars[offset...offset + 1]), radix: 16)))
        }
        return result
    }
    private func bytes(_ spec: Packet) throws -> Data {
        if let value = spec.hex { return try hex(value) }
        let count = try XCTUnwrap(spec.count); try require((0...65_536).contains(count))
        return Data(repeating: try XCTUnwrap(spec.byte), count: count)
    }
    private func input(_ spec: Wire) throws -> Data {
        let text: String
        if let supplied = spec.text { text = supplied }
        else {
            let count = spec.count ?? 0; try require((0...1_048_577).contains(count))
            text = (spec.prefix ?? "") + String(repeating: spec.token ?? "", count: count) + (spec.suffix ?? "")
        }
        var result = Data(text.utf8)
        if let count = spec.padTo {
            try require((result.count...1_048_577).contains(count)); result.append(Data(repeating: 32, count: count - result.count))
        }
        if let appended = spec.appendHex { result.append(try hex(appended)) }
        return result
    }
    private func packet(_ spec: Packet) throws -> RemoteHarnessControlPacket {
        switch spec.type {
        case "secure.handshake": return .handshake(try RemoteHarnessSecureHandshake(connectionID: spec.connectionId,
            targetDeviceID: spec.targetDeviceId, step: XCTUnwrap(spec.step), bytes: bytes(spec)))
        case "relay": return .relay(try RemoteHarnessSecureRelay(connectionID: spec.connectionId,
            targetDeviceID: spec.targetDeviceId, counter: XCTUnwrap(spec.counter), ciphertext: bytes(spec)))
        default: throw Mismatch.fixture
        }
    }
    private func compare(_ envelope: RemoteHarnessControlEnvelope, _ spec: Packet) throws {
        try require(same(envelope.id, spec.id) && envelope.timestamp == spec.timestamp)
        let expected = try bytes(spec)
        switch envelope.packet {
        case let .handshake(value):
            try require(spec.type == "secure.handshake" && same(value.connectionID, spec.connectionId) && same(value.targetDeviceID, spec.targetDeviceId))
            try require(value.step == spec.step && value.bytes == expected)
        case let .relay(value):
            try require(spec.type == "relay" && same(value.connectionID, spec.connectionId) && same(value.targetDeviceID, spec.targetDeviceId))
            try require(value.counter == spec.counter && value.ciphertext == expected)
        }
        // Literal fixture values independently establish exact type and binary
        // producer output, and omission of unknown payload keys after decoding.
        let encoded = try RemoteHarnessControlWire().encode(envelope.packet, id: envelope.id, timestamp: envelope.timestamp)
        let fields = try RemoteHarnessJSON(data: encoded).fields()
        try require(Set(fields.keys) == ["v", "id", "type", "timestamp", "payload"])
        try require(try fields.required("type").stringValue() == spec.type)
        let payload = try fields.required("payload").fields()
        let handshake = spec.type == "secure.handshake"
        try require(Set(payload.keys) == (handshake ? ["connectionId", "targetDeviceId", "step", "data"] : ["connectionId", "targetDeviceId", "counter", "ciphertext"]))
        if let base64 = spec.base64 { try require(try payload.required(handshake ? "data" : "ciphertext").stringValue() == base64) }
    }
    private func privacy() throws {
        var mutable = Data([0, 0xff, 0x80])
        let packet = RemoteHarnessControlPacket.relay(try RemoteHarnessSecureRelay(connectionID: "private-connection", targetDeviceID: "private-target", counter: 0, ciphertext: mutable))
        mutable.resetBytes(in: mutable.startIndex..<mutable.endIndex)
        var encoded = try RemoteHarnessControlWire().encode(packet, id: "private-header", timestamp: 1)
        // A nonzero-index Data slice must remain a valid input.
        var padded = Data([0]); padded.append(encoded)
        let decoded = try RemoteHarnessControlWire().decode(padded[(padded.startIndex + 1)..<padded.endIndex])
        encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex)
        padded.resetBytes(in: padded.startIndex..<padded.endIndex)
        guard case let .relay(value) = decoded.packet else { throw Mismatch.fixture }
        try require(value.ciphertext == Data([0, 0xff, 0x80]))
        var exported = value.ciphertext; exported.resetBytes(in: exported.startIndex..<exported.endIndex)
        try require(value.ciphertext == Data([0, 0xff, 0x80]))
        try require(String(describing: decoded) == "RemoteHarnessControlEnvelope(redacted)")
        try require(String(reflecting: decoded) == "RemoteHarnessControlEnvelope(redacted)")
        try require(String(describing: packet) == "RemoteHarnessControlPacket(redacted)")
        try require(String(describing: RemoteHarnessControlWire()) == "RemoteHarnessControlWire(redacted)")
        let limits = try RemoteHarnessControlWireLimits()
        try require(String(describing: limits) == "RemoteHarnessControlWireLimits(redacted)")
        try require(Mirror(reflecting: decoded).children.isEmpty && Mirror(reflecting: packet).children.isEmpty && Mirror(reflecting: limits).children.isEmpty)
        var dumped = ""; dump(decoded, to: &dumped)
        try require(!dumped.contains("private-header") && !dumped.contains("private-connection") && !dumped.contains("ciphertext"))
    }

    func testSharedSyntheticControlWireFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: root.appendingPathComponent("shared/remote-harness-control-wire-fixtures.json"))
        try require(source.count <= 262_144)
        let document = try JSONDecoder().decode(Document.self, from: source)
        try require(document.schemaVersion == 1 && document.upstreamRevision == "9a60e783ec1ceaff6116b0462a2863f07f602a55" && document.origin.hasPrefix("Original Quenderin"))
        var seen: Set<String> = []
        for fixture in document.cases {
            try require(seen.insert(fixture.id).inserted)
            do {
                for step in fixture.steps {
                    let reject = step.reject ?? false
                    func execute() throws {
                        let limits = try RemoteHarnessControlWireLimits(handshake: step.config?.handshake, relay: step.config?.relay)
                        switch step.action {
                        case "decode":
                            let result = try RemoteHarnessControlWire().decode(input(XCTUnwrap(step.wire)), limits: limits)
                            if !reject { try compare(result, XCTUnwrap(step.expected)) }
                        case "roundTrip":
                            let spec = try XCTUnwrap(step.packet)
                            let encoded = try RemoteHarnessControlWire().encode(packet(spec), id: spec.id, timestamp: spec.timestamp, limits: limits)
                            if !reject { try compare(RemoteHarnessControlWire().decode(encoded, limits: limits), spec) }
                        case "config":
                            if !reject { try require(limits.handshake == step.expectedHandshake && limits.relay == step.expectedRelay) }
                        case "privacy": try privacy()
                        default: throw Mismatch.fixture
                        }
                    }
                    if reject {
                        var rejected = false
                        do { try execute() } catch is Mismatch { throw Mismatch.fixture } catch { rejected = true }
                        try require(rejected)
                    } else { try execute() }
                }
            } catch { XCTFail("Control wire fixture failed: \(fixture.id)"); throw Mismatch.fixture }
            emitFixturePass("REMOTE_HARNESS_CONTROL_WIRE_FIXTURE_PASS \(fixture.id)")
        }
    }
}
