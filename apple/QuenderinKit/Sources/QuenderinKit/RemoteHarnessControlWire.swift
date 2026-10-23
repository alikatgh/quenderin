import Foundation

/// The secure control subset only. Authentication, sockets, enrollment and the
/// locally retained channel generation are deliberately outside this codec.
public enum RemoteHarnessControlWireError: String, Error, Sendable, CustomStringConvertible {
    case invalidFrame, unsupportedType, limitExceeded, invalidBase64, invalidLimits
    public var description: String { "Remote Harness control wire: \(rawValue)" }
}

public struct RemoteHarnessControlWireLimits: Sendable, NativeConnectionPrivateValue {
    public static let handshakeBytes = 65_536
    public static let relayBytes = 1_048_576
    public static let defaults = Self(handshakeBytes: handshakeBytes, relayBytes: relayBytes)
    public let handshake: Int
    public let relay: Int
    private init(handshakeBytes: Int, relayBytes: Int) { handshake = handshakeBytes; relay = relayBytes }
    public init(handshake: Int64? = nil, relay: Int64? = nil) throws {
        func bound(_ value: Int64?, _ maximum: Int) throws -> Int {
            guard let value else { return maximum }
            guard value > 0, value <= NativeConnectionBounds.counter else { throw RemoteHarnessControlWireError.invalidLimits }
            return Int(min(value, Int64(maximum)))
        }
        self.handshake = try bound(handshake, Self.handshakeBytes)
        self.relay = try bound(relay, Self.relayBytes)
    }
}

public enum RemoteHarnessControlPacket: Sendable, NativeConnectionPrivateValue {
    case handshake(RemoteHarnessSecureHandshake)
    case relay(RemoteHarnessSecureRelay)
}

public struct RemoteHarnessControlEnvelope: Sendable, NativeConnectionPrivateValue {
    public let id: String
    public let timestamp: Int64
    public let packet: RemoteHarnessControlPacket
    fileprivate init(id: String, timestamp: Int64, packet: RemoteHarnessControlPacket) {
        self.id = id; self.timestamp = timestamp; self.packet = packet
    }
}

public struct RemoteHarnessControlWire: Sendable, NativeConnectionPrivateValue {
    private static let binaryBytes = 65_535
    private static let encodedCharacters = 87_380
    public init() {}
    private func identity(_ value: String) throws {
        // Reuse the secure-link identifier validation; no normalization or UUID assumption.
        _ = try RemoteHarnessSecureClientID(value)
    }
    private func positive(_ value: Int64) throws {
        guard value > 0, value <= NativeConnectionBounds.counter else { throw RemoteHarnessControlWireError.invalidFrame }
    }
    private func base64(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count <= Self.binaryBytes else { throw RemoteHarnessControlWireError.limitExceeded }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func binary(_ value: RemoteHarnessJSON) throws -> Data {
        let text = try value.stringValue()
        guard !text.isEmpty, text.utf8.count <= Self.encodedCharacters, text.utf8.count % 4 != 1,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { throw RemoteHarnessControlWireError.invalidBase64 }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.count <= Self.binaryBytes,
              try base64(bytes).utf8.elementsEqual(text.utf8) else { throw RemoteHarnessControlWireError.invalidBase64 }
        return bytes
    }
    public func encode(_ packet: RemoteHarnessControlPacket, id: String, timestamp: Int64,
                       limits: RemoteHarnessControlWireLimits = .defaults) throws -> Data {
        try identity(id); try positive(timestamp)
        let type: String, payload: RemoteHarnessJSON, maximum: Int
        switch packet {
        case let .handshake(value):
            try identity(value.connectionID); try identity(value.targetDeviceID)
            guard value.step == 1 || value.step == 2 else { throw RemoteHarnessControlWireError.invalidFrame }
            type = "secure.handshake"; maximum = limits.handshake
            payload = try .object(["connectionId": .string(value.connectionID), "targetDeviceId": .string(value.targetDeviceID),
                                   "step": .integer(Int64(value.step)), "data": .string(base64(value.bytes))])
        case let .relay(value):
            try identity(value.connectionID); try identity(value.targetDeviceID)
            guard value.counter >= 0, value.counter <= NativeConnectionBounds.counter else { throw RemoteHarnessControlWireError.invalidFrame }
            type = "relay"; maximum = limits.relay
            payload = try .object(["connectionId": .string(value.connectionID), "targetDeviceId": .string(value.targetDeviceID),
                                   "counter": .integer(value.counter), "ciphertext": .string(base64(value.ciphertext))])
        }
        let frame = try RemoteHarnessJSON.object(["v": .integer(1), "id": .string(id), "type": .string(type),
                                                 "timestamp": .integer(timestamp), "payload": payload]).data
        guard frame.count <= maximum else { throw RemoteHarnessControlWireError.limitExceeded }
        return frame
    }
    public func decode(_ bytes: Data, limits: RemoteHarnessControlWireLimits = .defaults) throws -> RemoteHarnessControlEnvelope {
        guard bytes.count <= RemoteHarnessControlWireLimits.relayBytes else { throw RemoteHarnessControlWireError.limitExceeded }
        let fields = try RemoteHarnessJSON(data: bytes).fields()
        try fields.requireKeys(["v", "id", "type", "timestamp", "payload"])
        guard try fields.required("v").integerValue() == 1 else { throw RemoteHarnessControlWireError.invalidFrame }
        let id = try fields.required("id").stringValue(); try identity(id)
        let timestamp = try fields.required("timestamp").integerValue(); try positive(timestamp)
        let type = try fields.required("type").stringValue()
        let maximum: Int
        switch type {
        case "secure.handshake": maximum = limits.handshake
        case "relay": maximum = limits.relay
        default: throw RemoteHarnessControlWireError.unsupportedType
        }
        guard bytes.count <= maximum else { throw RemoteHarnessControlWireError.limitExceeded }
        // Upstream payload objects strip unknown fields; the common envelope is strict.
        let payload = try fields.required("payload").fields()
        let connection = try payload.required("connectionId").stringValue()
        let target = try payload.required("targetDeviceId").stringValue()
        try identity(connection); try identity(target)
        let packet: RemoteHarnessControlPacket
        if type == "secure.handshake" {
            let step = try payload.required("step").integerValue()
            guard step == 1 || step == 2 else { throw RemoteHarnessControlWireError.invalidFrame }
            packet = .handshake(try RemoteHarnessSecureHandshake(connectionID: connection, targetDeviceID: target,
                step: Int(step), bytes: binary(payload.required("data"))))
        } else {
            packet = .relay(try RemoteHarnessSecureRelay(connectionID: connection, targetDeviceID: target,
                counter: payload.required("counter").integerValue(), ciphertext: binary(payload.required("ciphertext"))))
        }
        return RemoteHarnessControlEnvelope(id: id, timestamp: timestamp, packet: packet)
    }
}
