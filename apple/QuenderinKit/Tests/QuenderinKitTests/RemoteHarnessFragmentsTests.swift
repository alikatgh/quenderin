import Foundation
import XCTest
@testable import QuenderinKit

@MainActor
final class RemoteHarnessFragmentsTests: XCTestCase {
    private enum Mismatch: Error { case fixture }
    private struct Repeated: Decodable { let count: Int; let byte: UInt8?; let patternHex: String? }
    private struct Bytes: Decodable {
        let hex: String?
        let headerHex: String?
        let count: Int?
        let byte: UInt8?
        let patternHex: String?
        let payload: Repeated?
    }
    private struct Step: Decodable {
        let action: String
        let message: Bytes?
        let frame: Bytes?
        let result: Bytes?
        let expectedFrames: [Bytes]?
        let generation: UInt64?
        let now: Int64?
        let error: String?
        let assemblies: Int?
        let declared: Int?
        let retired: Bool?
        let frameCount: Int?
        let firstHeaderHex: String?
        let lastHeaderHex: String?
        let count: Int?
    }
    private struct Fixture: Decodable {
        let id: String
        let initialMessageID: UInt64?
        let steps: [Step]
    }
    private struct Document: Decodable {
        let schemaVersion: Int
        let upstreamRevision: String
        let cases: [Fixture]
    }
    private func require(_ value: Bool) throws { if !value { throw Mismatch.fixture } }
    private func hex(_ source: String) throws -> Data {
        let characters = Array(source)
        try require(characters.count % 2 == 0)
        var bytes = Data(); bytes.reserveCapacity(characters.count / 2)
        for offset in stride(from: 0, to: characters.count, by: 2) {
            bytes.append(try XCTUnwrap(UInt8(String(characters[offset...offset + 1]), radix: 16)))
        }
        return bytes
    }
    private func bytes(_ spec: Bytes) throws -> Data {
        if let source = spec.hex { return try hex(source) }
        var data = try hex(spec.headerHex ?? "")
        let count = spec.payload?.count ?? spec.count ?? 0
        let byte = spec.payload?.byte ?? spec.byte ?? 0
        try require((0...4_194_305).contains(count))
        if let patternHex = spec.payload?.patternHex ?? spec.patternHex {
            let pattern = Array(try hex(patternHex)); try require(!pattern.isEmpty)
            data.append(contentsOf: (0..<count).map { pattern[$0 % pattern.count] })
        } else { data.append(Data(repeating: byte, count: count)) }
        return data
    }
    private func expectError(_ code: String, _ block: () throws -> Void) throws {
        var actual: RemoteHarnessFragmentError?
        do { try block() } catch let error as RemoteHarnessFragmentError { actual = error }
        try require(actual?.rawValue == code)
    }
    private func syntheticFrame(id: UInt32, index: Int) throws -> Data {
        // Independent synthetic 49,153-byte golden message; vary only ID/index.
        var header = Array(try hex(index == 0 ? "445348460100000001000000020000c001" : "445348460100000001000100020000c001"))
        header[5] = UInt8(truncatingIfNeeded: id >> 24); header[6] = UInt8(truncatingIfNeeded: id >> 16)
        header[7] = UInt8(truncatingIfNeeded: id >> 8); header[8] = UInt8(truncatingIfNeeded: id)
        var frame = Data(header); frame.append(Data(repeating: 97, count: index == 0 ? 49_152 : 1))
        return frame
    }
    private func ownershipAndPrivacy() throws {
        let codec = try RemoteHarnessFragments(authenticatedGeneration: 1)
        var input = Data(repeating: 97, count: 49_153)
        let encoded = try codec.encode(input, authenticatedGeneration: 1)
        input.resetBytes(in: input.startIndex..<input.endIndex)
        try require(encoded[0].data.last == 97)
        var exported = encoded[0].data
        let original = exported
        exported.resetBytes(in: exported.startIndex..<exported.endIndex)
        try require(encoded[0].data == original)
        var padded = Data([0]); padded.append(original)
        var mutableWire = padded[(padded.startIndex + 1)..<padded.endIndex]
        try require(try codec.decode(mutableWire, authenticatedGeneration: 1, monotonicMilliseconds: 0) == nil)
        mutableWire.resetBytes(in: mutableWire.startIndex..<mutableWire.endIndex)
        let complete = try XCTUnwrap(codec.decode(encoded[1].data, authenticatedGeneration: 1, monotonicMilliseconds: 0))
        try require(complete.data == Data(repeating: 97, count: 49_153))
        var output = complete.data; output.resetBytes(in: output.startIndex..<output.endIndex)
        try require(complete.data.first == 97)
        var rawInput = Data([0xff, 0, 0x80])
        let raw = try XCTUnwrap(codec.decode(rawInput, authenticatedGeneration: 1, monotonicMilliseconds: 0))
        rawInput.resetBytes(in: rawInput.startIndex..<rawInput.endIndex)
        try require(raw.data == Data([0xff, 0, 0x80]))
        try require(String(describing: complete) == "RemoteHarnessFragmentBytes(redacted)")
        try require(String(reflecting: complete) == "RemoteHarnessFragmentBytes(redacted)")
        try require(Mirror(reflecting: complete).children.isEmpty && Mirror(reflecting: codec).children.isEmpty)
        try require(String(describing: codec) == "RemoteHarnessFragments(redacted)")
        var dumpText = ""; dump(complete, to: &dumpText)
        try require(!dumpText.contains("data:") && !dumpText.contains("49153"))
        try expectError("header") { _ = try codec.decode(hex("44534846"), authenticatedGeneration: 1, monotonicMilliseconds: 0) }
    }

    func testSharedSyntheticFragmentFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try Data(contentsOf: root.appendingPathComponent("shared/remote-harness-fragments-fixtures.json"))
        let document = try JSONDecoder().decode(Document.self, from: source)
        try require(document.schemaVersion == 1 && document.upstreamRevision == "9a60e783ec1ceaff6116b0462a2863f07f602a55")
        var seen: Set<String> = []
        for fixture in document.cases {
            try require(seen.insert(fixture.id).inserted)
            do {
                let codec = try RemoteHarnessFragments(authenticatedGeneration: 1, initialMessageID: fixture.initialMessageID ?? 1)
                for step in fixture.steps {
                    let generation = step.generation ?? 1, now = step.now ?? 0
                    func execute() throws {
                        switch step.action {
                        case "encode":
                            let result = try codec.encode(bytes(XCTUnwrap(step.message)), authenticatedGeneration: generation)
                            if let expected = step.expectedFrames {
                                try require(result.count == expected.count)
                                for index in expected.indices { try require(try result[index].data == bytes(expected[index])) }
                            }
                        case "decode":
                            let result = try codec.decode(bytes(XCTUnwrap(step.frame)), authenticatedGeneration: generation, monotonicMilliseconds: now)
                            if let expected = step.result { try require(try XCTUnwrap(result).data == bytes(expected)) }
                            else { try require(result == nil) }
                        case "roundTrip":
                            let message = try bytes(XCTUnwrap(step.message))
                            let frames = try codec.encode(message, authenticatedGeneration: generation)
                            try require(frames.count == step.frameCount)
                            try require(try Data(XCTUnwrap(frames.first).data.prefix(17)) == hex(XCTUnwrap(step.firstHeaderHex)))
                            try require(try Data(XCTUnwrap(frames.last).data.prefix(17)) == hex(XCTUnwrap(step.lastHeaderHex)))
                            for frame in frames.dropLast() { try require(try codec.decode(frame.data, authenticatedGeneration: generation, monotonicMilliseconds: now) == nil) }
                            let complete = try XCTUnwrap(codec.decode(XCTUnwrap(frames.last).data, authenticatedGeneration: generation, monotonicMilliseconds: now))
                            try require(complete.data == message && codec.assemblyCount == 0 && codec.declaredByteCount == 0)
                        case "state":
                            try require(codec.assemblyCount == step.assemblies && codec.declaredByteCount == step.declared && codec.isRetired == step.retired)
                        case "expire": try codec.checkExpiry(authenticatedGeneration: generation, monotonicMilliseconds: now)
                        case "reset": try codec.reset(newAuthenticatedGeneration: generation)
                        case "retire": try codec.retire(authenticatedGeneration: generation)
                        case "receivedIDLimit":
                            let count = try XCTUnwrap(step.count)
                            for ordinal in 1...count {
                                try require(try codec.decode(syntheticFrame(id: UInt32(ordinal), index: 0), authenticatedGeneration: generation, monotonicMilliseconds: now) == nil)
                                let complete = try XCTUnwrap(codec.decode(syntheticFrame(id: UInt32(ordinal), index: 1), authenticatedGeneration: generation, monotonicMilliseconds: now))
                                try require(complete.data.count == 49_153)
                            }
                            try expectError("idLimit") { _ = try codec.decode(syntheticFrame(id: UInt32(count + 1), index: 0), authenticatedGeneration: generation, monotonicMilliseconds: now) }
                        case "ownershipAndPrivacy": try ownershipAndPrivacy()
                        default: throw Mismatch.fixture
                        }
                    }
                    if let error = step.error { try expectError(error, execute) } else { try execute() }
                }
            } catch {
                XCTFail("REMOTE_HARNESS_FRAGMENT_FIXTURE_FAIL " + fixture.id)
                throw Mismatch.fixture
            }
            print("REMOTE_HARNESS_FRAGMENT_FIXTURE_PASS " + fixture.id)
        }
    }
}
