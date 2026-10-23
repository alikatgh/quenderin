import Foundation

/// Decrypted business messages only. This module does not authenticate a peer,
/// encrypt data, open a socket, or enable an upstream service.
public enum RemoteHarnessError: String, Error, Sendable, CustomStringConvertible, LocalizedError {
    case invalidJSON, invalidMessage, limitExceeded, unsupportedVersion, unsupportedCapability
    case conflictingCapabilities, endpointNotAllowed, disconnected, bindingMismatch, deadlineExceeded
    case journalUnavailable, duplicateCommand, outcomeUnknown, recoveryRequired, approvalBindingUnavailable
    public var description: String { "Remote Harness: \(rawValue)" }
    public var errorDescription: String? { description }
}

public enum RemoteHarnessLimits {
    public static let frameBytes = 4 * 1_024 * 1_024
    public static let pendingRPCs = 128
    public static let streams = 16
    public static let promptBytes = 65_536
    public static let deadlineMilliseconds: Int64 = 120_000
}

/// Unknown structured values retain their original UTF-8 bytes, including number
/// spelling and all nested fields. Explicit `data` access is a private-data export.
public struct RemoteHarnessJSON: Sendable, Equatable, NativeConnectionPrivateValue {
    public let data: Data
    public init(data: Data) throws {
        guard data.count <= RemoteHarnessLimits.frameBytes else { throw RemoteHarnessError.limitExceeded }
        do { try NativeStrictJSON.validate(data, integerNumbersOnly: false) }
        catch NativeConnectionError.limitExceeded { throw RemoteHarnessError.limitExceeded }
        catch { throw RemoteHarnessError.invalidJSON }
        self.data = data
    }
    fileprivate init(validated data: Data) { self.data = data }
    public static func string(_ value: String) throws -> Self {
        guard value.utf8.count <= RemoteHarnessLimits.frameBytes else { throw RemoteHarnessError.limitExceeded }
        return try Self(data: JSONEncoder().encode(value))
    }
    public static func integer(_ value: Int64) throws -> Self {
        guard value >= 0, value <= NativeConnectionBounds.counter else { throw RemoteHarnessError.invalidMessage }
        return Self(validated: Data(String(value).utf8))
    }
    public static func boolean(_ value: Bool) -> Self { Self(validated: Data((value ? "true" : "false").utf8)) }
    public static func object(_ values: [String: Self]) throws -> Self {
        guard values.count <= 1_024 else { throw RemoteHarnessError.limitExceeded }
        var bytes = Data("{".utf8)
        for key in values.keys.sorted() {
            if bytes.count > 1 { bytes.append(44) }
            let encodedKey = try Self.string(key)
            guard let value = values[key], bytes.count + encodedKey.data.count + value.data.count + 2 <= RemoteHarnessLimits.frameBytes
            else { throw RemoteHarnessError.limitExceeded }
            bytes.append(encodedKey.data); bytes.append(58); bytes.append(value.data)
        }
        bytes.append(125)
        return try Self(data: bytes)
    }
    public static func array(_ values: [Self]) throws -> Self {
        guard values.count <= 1_024 else { throw RemoteHarnessError.limitExceeded }
        var bytes = Data("[".utf8)
        for value in values {
            guard bytes.count + value.data.count + 2 <= RemoteHarnessLimits.frameBytes else { throw RemoteHarnessError.limitExceeded }
            if bytes.count > 1 { bytes.append(44) }
            bytes.append(value.data)
        }
        bytes.append(93)
        return try Self(data: bytes)
    }
    public func fields() throws -> [String: Self] {
        var scanner = RemoteHarnessSlices(data)
        return try scanner.object()
    }
    public func elements() throws -> [Self] {
        var scanner = RemoteHarnessSlices(data)
        return try scanner.array()
    }
    public func stringValue() throws -> String {
        do { return try JSONDecoder().decode(String.self, from: data) }
        catch { throw RemoteHarnessError.invalidMessage }
    }
    public func integerValue() throws -> Int64 {
        // Foundation's Int64 JSON decoder can accept decimal/exponent tokens
        // and round them. Protocol counters require their actual wire spelling
        // to be an unsigned ASCII integer; opaque numbers remain raw bytes.
        guard (1...16).contains(data.count), data.allSatisfy({ (48...57).contains($0) }),
              let result = Int64(String(decoding: data, as: UTF8.self)),
              result <= NativeConnectionBounds.counter else { throw RemoteHarnessError.invalidMessage }
        return result
    }
    public func booleanValue() throws -> Bool {
        do { return try JSONDecoder().decode(Bool.self, from: data) }
        catch { throw RemoteHarnessError.invalidMessage }
    }
}

/// Only visits already strictly validated JSON. It slices values rather than
/// decoding unknown payloads through NSNumber (which can change numeric values).
private struct RemoteHarnessSlices {
    let bytes: [UInt8]
    var cursor = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func space() { while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        space(); guard cursor < bytes.count, bytes[cursor] == byte else { throw RemoteHarnessError.invalidMessage }; cursor += 1
    }
    mutating func stringEnd() throws {
        try consume(34)
        while cursor < bytes.count {
            let byte = bytes[cursor]; cursor += 1
            if byte == 34 { return }
            if byte == 92 { cursor += 1 }
        }
        throw RemoteHarnessError.invalidMessage
    }
    mutating func value() throws -> RemoteHarnessJSON {
        space(); let start = cursor
        guard cursor < bytes.count else { throw RemoteHarnessError.invalidMessage }
        switch bytes[cursor] {
        case 34: try stringEnd()
        case 123, 91:
            let closing: UInt8 = bytes[cursor] == 123 ? 125 : 93
            cursor += 1
            while true {
                space(); guard cursor < bytes.count else { throw RemoteHarnessError.invalidMessage }
                if bytes[cursor] == closing { cursor += 1; break }
                if [44, 58].contains(bytes[cursor]) { cursor += 1 } else { _ = try value() }
            }
        default:
            while cursor < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
        }
        return RemoteHarnessJSON(validated: Data(bytes[start..<cursor]))
    }
    mutating func object() throws -> [String: RemoteHarnessJSON] {
        try consume(123); var result: [String: RemoteHarnessJSON] = [:]
        space(); if cursor < bytes.count, bytes[cursor] == 125 { return result }
        while true {
            let key = try value().stringValue(); try consume(58); result[key] = try value()
            space(); guard cursor < bytes.count else { throw RemoteHarnessError.invalidMessage }
            if bytes[cursor] == 125 { return result }
            try consume(44)
        }
    }
    mutating func array() throws -> [RemoteHarnessJSON] {
        try consume(91); var result: [RemoteHarnessJSON] = []
        space(); if cursor < bytes.count, bytes[cursor] == 93 { return result }
        while true {
            result.append(try value()); space()
            guard cursor < bytes.count else { throw RemoteHarnessError.invalidMessage }
            if bytes[cursor] == 93 { return result }
            try consume(44)
        }
    }
}

extension Dictionary where Key == String, Value == RemoteHarnessJSON {
    func required(_ key: String) throws -> Value {
        guard let value = self[key] else { throw RemoteHarnessError.invalidMessage }; return value
    }
    func requireKeys(_ required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(keys)), Set(keys).isSubset(of: required.union(optional)) else { throw RemoteHarnessError.invalidMessage }
    }
    func text(_ key: String) throws -> String {
        let text = try required(key).stringValue()
        guard !text.isEmpty, text.utf8.count <= 1_024 else { throw RemoteHarnessError.invalidMessage }; return text
    }
}

public struct RemoteHarnessFailure: Sendable, Equatable, NativeConnectionPrivateValue {
    public let code: String
    public let message: String
    public let details: RemoteHarnessJSON?
    public let retryable: Bool?
    init(_ value: RemoteHarnessJSON, requestID: Bool = false) throws {
        let fields = try value.fields()
        try fields.requireKeys(requestID ? ["requestId", "code", "message"] : ["code", "message"], optional: ["details", "retryable"])
        code = try fields.text("code")
        message = try fields.required("message").stringValue()
        details = fields["details"]
        retryable = try fields["retryable"]?.booleanValue()
    }
}

public enum RemoteHarnessGatewayResult: Sendable, Equatable, NativeConnectionPrivateValue {
    case success(RemoteHarnessJSON?)
    case failure(RemoteHarnessFailure)
    public init(_ value: RemoteHarnessJSON) throws {
        let fields = try value.fields()
        if try fields.required("ok").booleanValue() {
            try fields.requireKeys(["ok"], optional: ["value"]); self = .success(fields["value"])
        } else {
            try fields.requireKeys(["ok", "error"]); self = .failure(try RemoteHarnessFailure(fields.required("error")))
        }
    }
}

public enum RemoteHarnessMessageType: String, Sendable { case request = "rpc.request", response = "rpc.response", error = "rpc.error", event }
public enum RemoteHarnessCloseReason: String, Sendable { case cancelled, completed, failed, peerDisconnected = "peer-disconnected" }
public enum RemoteHarnessMessageBody: Sendable, Equatable, NativeConnectionPrivateValue {
    case request(method: RemoteHarnessMethod, params: RemoteHarnessJSON)
    case response(requestID: String, result: RemoteHarnessJSON)
    case error(requestID: String, failure: RemoteHarnessFailure)
    case event(name: String, data: RemoteHarnessJSON, sequence: Int64?, sessionID: String?)
}
public struct RemoteHarnessMessage: Sendable, Equatable, NativeConnectionPrivateValue {
    public let id: String
    public let timestamp: Int64
    public let type: RemoteHarnessMessageType
    public let body: RemoteHarnessMessageBody
    public let rawJSON: RemoteHarnessJSON
}

/// Pinned to ds-harness-remote 9a60e783ec1ceaff6116b0462a2863f07f602a55.
public struct RemoteHarnessCodec: Sendable {
    public init() {}
    public func encodeRequest(id: String, timestamp: Int64, operation: RemoteHarnessOperation) throws -> Data {
        guard !id.isEmpty, id.utf8.count <= 1_024, timestamp > 0 else { throw RemoteHarnessError.invalidMessage }
        let payload = try RemoteHarnessJSON.object(["method": .string(operation.method.rawValue), "params": operation.params])
        return try RemoteHarnessJSON.object(["v": .integer(1), "id": .string(id), "type": .string("rpc.request"), "timestamp": .integer(timestamp), "payload": payload]).data
    }
    public func decode(_ data: Data) throws -> RemoteHarnessMessage {
        let raw = try RemoteHarnessJSON(data: data), fields = try raw.fields()
        try fields.requireKeys(["v", "id", "type", "timestamp", "payload"])
        guard try fields.required("v").integerValue() == 1 else { throw RemoteHarnessError.unsupportedVersion }
        let id = try fields.text("id"), timestamp = try fields.required("timestamp").integerValue()
        guard timestamp > 0, let type = RemoteHarnessMessageType(rawValue: try fields.text("type")) else { throw RemoteHarnessError.invalidMessage }
        let payload = try fields.required("payload"), values = try payload.fields()
        let body: RemoteHarnessMessageBody
        switch type {
        case .request:
            try values.requireKeys(["method", "params"])
            guard let method = RemoteHarnessMethod(rawValue: try values.text("method")) else { throw RemoteHarnessError.endpointNotAllowed }
            let operation = try RemoteHarnessOperation(method: method, params: values.required("params"))
            body = .request(method: method, params: operation.params)
        case .response:
            try values.requireKeys(["requestId", "result"])
            body = .response(requestID: try values.text("requestId"), result: try values.required("result"))
        case .error:
            body = .error(requestID: try values.text("requestId"), failure: try RemoteHarnessFailure(payload, requestID: true))
        case .event:
            try values.requireKeys(["event", "data"], optional: ["seq", "sessionId"])
            body = .event(name: try values.text("event"), data: try values.required("data"), sequence: try values["seq"]?.integerValue(), sessionID: try values["sessionId"]?.stringValue())
        }
        return RemoteHarnessMessage(id: id, timestamp: timestamp, type: type, body: body, rawJSON: raw)
    }
}
