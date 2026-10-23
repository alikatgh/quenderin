import Foundation

/// Fixed diagnostics intentionally carry no provider content, endpoints, or raw decoder errors.
public enum NativeConnectionError: String, Error, Sendable, CustomStringConvertible, LocalizedError {
    case invalidJSON, invalidValue, unsupportedVersion, limitExceeded, dispatchMismatch
    case sessionMismatch, unknownCommand, invalidTransition, approvalUnavailable, approvalExpired
    public var description: String { "Native connection validation: \(rawValue)" }
    public var errorDescription: String? { description }
}

enum NativeConnectionBounds {
    static let envelopeBytes = 8_388_608
    static let messages = 1_024
    static let textBytes = 1_048_576
    static let toolCalls = 128
    static let documents = 32
    static let pending = 128
    static let depth = 32
    static let counter: Int64 = 9_007_199_254_740_991

    static func identifier(_ value: String) throws {
        guard (1...128).contains(value.utf8.count), value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }) else { throw NativeConnectionError.invalidValue }
    }
    static func text(_ value: String) throws {
        guard value.utf8.count <= textBytes else { throw NativeConnectionError.limitExceeded }
    }
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw NativeConnectionError.invalidValue }
    }
    static func counter(_ value: Int64, positive: Bool = false) throws {
        guard value >= (positive ? 1 : 0), value <= counter else { throw NativeConnectionError.invalidValue }
    }
    static func unique(_ values: [String]) throws {
        guard Set(values).count == values.count else { throw NativeConnectionError.invalidValue }
    }
}

/// A cheap lower bound before encoding, so a programmatic 1,024-message envelope cannot
/// allocate a gigabyte in JSONEncoder merely to discover the 8 MiB limit afterward.
struct NativeWireSizeBudget {
    private var remaining = NativeConnectionBounds.envelopeBytes
    mutating func include(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count <= remaining else { throw NativeConnectionError.limitExceeded }
        remaining -= value.utf8.count
    }
}

struct NativeKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

struct NativeFields {
    let values: KeyedDecodingContainer<NativeKey>
    init(_ decoder: Decoder, allowed: Set<String>) throws {
        values = try decoder.container(keyedBy: NativeKey.self)
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw NativeConnectionError.invalidValue }
    }
    func required<T: Decodable>(_ key: String) throws -> T { try values.decode(T.self, forKey: NativeKey(key)) }
    func optional<T: Decodable>(_ key: String) throws -> T? {
        let key = NativeKey(key)
        guard values.contains(key) else { return nil }
        // A present null never substitutes for a typed optional field.
        return try values.decode(T.self, forKey: key)
    }
    func array<T: Decodable>(_ key: String) throws -> [T] { try optional(key) ?? [] }
}

protocol NativeWireObject: Codable {
    static var wireKeys: Set<String> { get }
    init(fields: NativeFields) throws
    func encodeFields(to values: inout KeyedEncodingContainer<NativeKey>) throws
}

extension NativeWireObject {
    public init(from decoder: Decoder) throws {
        do { try self.init(fields: NativeFields(decoder, allowed: Self.wireKeys)) }
        catch let error as NativeConnectionError { throw error }
        catch { throw NativeConnectionError.invalidValue }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: NativeKey.self)
        do { try encodeFields(to: &values) }
        catch { throw NativeConnectionError.invalidValue }
    }
}

extension KeyedEncodingContainer where Key == NativeKey {
    mutating func put<T: Encodable>(_ key: String, _ value: T) throws { try encode(value, forKey: NativeKey(key)) }
    mutating func putOptional<T: Encodable>(_ key: String, _ value: T?) throws {
        if let value { try put(key, value) }
    }
    mutating func putArray<T: Encodable>(_ key: String, _ value: [T]) throws {
        if !value.isEmpty { try put(key, value) }
    }
}

protocol NativeWireEnum: RawRepresentable, Codable where RawValue == String {}
extension NativeWireEnum {
    public init(from decoder: Decoder) throws {
        do {
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let parsed = Self(rawValue: value) else { throw NativeConnectionError.invalidValue }
            self = parsed
        } catch { throw NativeConnectionError.invalidValue }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

/// JSONDecoder deliberately loses duplicate keys. Inspect the actual bytes FIRST at every
/// persisted-data boundary. This scanner also rejects malformed UTF-8/surrogates and caps
/// container nesting before Foundation allocates an arbitrary decoded object tree.
struct NativeStrictJSON {
    private let bytes: [UInt8]
    private let integerNumbersOnly: Bool
    private var position = 0

    static func validate(_ data: Data, integerNumbersOnly: Bool = true) throws {
        guard data.count <= NativeConnectionBounds.envelopeBytes else { throw NativeConnectionError.limitExceeded }
        guard String(data: data, encoding: .utf8) != nil else { throw NativeConnectionError.invalidJSON }
        var scanner = Self(bytes: Array(data), integerNumbersOnly: integerNumbersOnly)
        try scanner.value(depth: 0)
        scanner.space()
        guard scanner.position == scanner.bytes.count else { throw NativeConnectionError.invalidJSON }
    }
    private mutating func space() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        space()
        if position < bytes.count, bytes[position] == byte { position += 1; return true }
        return false
    }
    private mutating func value(depth: Int) throws {
        space()
        guard depth < NativeConnectionBounds.depth else { throw NativeConnectionError.limitExceeded }
        guard position < bytes.count else { throw NativeConnectionError.invalidJSON }
        switch bytes[position] {
        case 123:
            guard depth < NativeConnectionBounds.depth else { throw NativeConnectionError.limitExceeded }
            position += 1
            var keys = Set<String>()
            if take(125) { return }
            while true {
                guard keys.count < NativeConnectionBounds.messages else { throw NativeConnectionError.limitExceeded }
                let key = try string(decode: true)
                guard keys.insert(key).inserted, take(58) else { throw NativeConnectionError.invalidJSON }
                try value(depth: depth + 1)
                if take(125) { return }
                guard take(44) else { throw NativeConnectionError.invalidJSON }
            }
        case 91:
            guard depth < NativeConnectionBounds.depth else { throw NativeConnectionError.limitExceeded }
            position += 1
            if take(93) { return }
            var count = 0
            while true {
                guard count < NativeConnectionBounds.messages else { throw NativeConnectionError.limitExceeded }
                try value(depth: depth + 1)
                count += 1
                if take(93) { return }
                guard take(44) else { throw NativeConnectionError.invalidJSON }
            }
        case 34: _ = try string(decode: false)
        case 116: try literal([116, 114, 117, 101])
        case 102: try literal([102, 97, 108, 115, 101])
        case 110: try literal([110, 117, 108, 108])
        default: try number()
        }
    }
    private mutating func literal(_ expected: [UInt8]) throws {
        guard bytes.count - position >= expected.count,
              Array(bytes[position..<(position + expected.count)]) == expected else { throw NativeConnectionError.invalidJSON }
        position += expected.count
    }
    private mutating func hex() throws -> UInt16 {
        guard bytes.count - position >= 4 else { throw NativeConnectionError.invalidJSON }
        var result: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[position]; position += 1
            let digit: UInt16
            switch byte {
            case 48...57: digit = UInt16(byte - 48)
            case 65...70: digit = UInt16(byte - 55)
            case 97...102: digit = UInt16(byte - 87)
            default: throw NativeConnectionError.invalidJSON
            }
            result = result * 16 + digit
        }
        return result
    }
    private mutating func string(decode: Bool) throws -> String {
        space()
        let start = position
        guard position < bytes.count, bytes[position] == 34 else { throw NativeConnectionError.invalidJSON }
        position += 1
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 34 {
                guard decode else { return "" }
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                catch { throw NativeConnectionError.invalidJSON }
            }
            guard byte >= 32 else { throw NativeConnectionError.invalidJSON }
            if byte == 92 {
                guard position < bytes.count else { throw NativeConnectionError.invalidJSON }
                let escaped = bytes[position]; position += 1
                if escaped == 117 {
                    let scalar = try hex()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard bytes.count - position >= 2, bytes[position] == 92, bytes[position + 1] == 117
                        else { throw NativeConnectionError.invalidJSON }
                        position += 2
                        guard (0xDC00...0xDFFF).contains(try hex()) else { throw NativeConnectionError.invalidJSON }
                    } else if (0xDC00...0xDFFF).contains(scalar) { throw NativeConnectionError.invalidJSON }
                } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escaped) {
                    throw NativeConnectionError.invalidJSON
                }
            }
        }
        throw NativeConnectionError.invalidJSON
    }
    private mutating func number() throws {
        let start = position
        if position < bytes.count, bytes[position] == 45 { position += 1 }
        guard position < bytes.count else { throw NativeConnectionError.invalidJSON }
        if bytes[position] == 48 { position += 1 }
        else {
            guard (49...57).contains(bytes[position]) else { throw NativeConnectionError.invalidJSON }
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
        }
        if position < bytes.count, bytes[position] == 46 {
            guard !integerNumbersOnly else { throw NativeConnectionError.invalidJSON }
            position += 1
            let digits = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            guard position > digits else { throw NativeConnectionError.invalidJSON }
        }
        if position < bytes.count, [69, 101].contains(bytes[position]) {
            guard !integerNumbersOnly else { throw NativeConnectionError.invalidJSON }
            position += 1
            if position < bytes.count, [43, 45].contains(bytes[position]) { position += 1 }
            let digits = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            guard position > digits else { throw NativeConnectionError.invalidJSON }
        }
        guard position > start else { throw NativeConnectionError.invalidJSON }
    }
}
