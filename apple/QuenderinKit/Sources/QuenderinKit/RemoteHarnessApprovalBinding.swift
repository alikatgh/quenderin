import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Matches the Host companion's sorted-object JSON.stringify action digest.
/// Number spelling follows ECMAScript's shortest finite Double representation,
/// including its fixed/scientific thresholds and negative-zero normalization.
enum RemoteHarnessApprovalDigest {
    static func digest(_ request: RemoteHarnessJSON) throws -> String {
        var nodes = 0
        let bytes = try canonical(request, depth: 0, nodes: &nodes)
        guard bytes.count <= 65_536 else { throw RemoteHarnessError.limitExceeded }
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        // Explicit carrier/SDK source closures need no application storage
        // dependency. Approval stays unavailable without native SHA-256.
        throw RemoteHarnessError.approvalBindingUnavailable
        #endif
    }
    static func canonical(_ value: RemoteHarnessJSON, depth: Int = 0, nodes: inout Int) throws -> Data {
        nodes += 1; guard nodes <= 8192, depth <= 32 else { throw RemoteHarnessError.limitExceeded }
        if let fields = try? value.fields() {
            // JavaScript always enumerates array-index property keys first,
            // even after Object.fromEntries received lexicographically sorted keys.
            func index(_ key: String) -> UInt32? { guard let n = UInt32(key), n < UInt32.max, String(n) == key else { return nil }; return n }
            let keys = fields.keys.sorted { a, b in
                switch (index(a), index(b)) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.utf16.lexicographicallyPrecedes(b.utf16)
                }
            }
            var output = Data("{".utf8)
            for key in keys {
                if output.count > 1 { output.append(44) }
                output.append(try quote(key)); output.append(58)
                output.append(try canonical(fields[key]!, depth: depth + 1, nodes: &nodes))
                guard output.count <= 65_536 else { throw RemoteHarnessError.limitExceeded }
            }
            output.append(125); return output
        }
        if let list = try? value.elements() {
            var output = Data("[".utf8)
            for element in list {
                if output.count > 1 { output.append(44) }
                output.append(try canonical(element, depth: depth + 1, nodes: &nodes)); guard output.count <= 65_536 else { throw RemoteHarnessError.limitExceeded }
            }
            output.append(93); return output
        }
        if let string = try? value.stringValue() { return try quote(string) }
        if let boolean = try? value.booleanValue() { return Data((boolean ? "true" : "false").utf8) }
        if value.data == Data("null".utf8) { return value.data }
        // JSON.parse normalizes a zero significand regardless of exponent
        // magnitude; avoid Foundation's platform-specific overflow handling.
        let numberToken = String(decoding: value.data, as: UTF8.self)
        let significand = numberToken.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
        if significand.contains("0"), significand.allSatisfy({ $0 == "0" || $0 == "." || $0 == "-" }) { return Data("0".utf8) }
        let number = try JSONDecoder().decode(Double.self, from: value.data)
        guard number.isFinite else { throw RemoteHarnessError.invalidMessage }
        if number == 0 { return Data("0".utf8) }
        let negative = number < 0
        let spelling = String(number.magnitude).lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let exponent = spelling.count == 2 ? Int(spelling[1])! : 0
        let pieces = spelling[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = pieces.map(String.init).joined(), position = pieces[0].count + exponent
        while digits.first == "0" { digits.removeFirst(); position -= 1 }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let power = position - 1
        var result: String
        if (-6...20).contains(power) {
            if position <= 0 { result = "0." + String(repeating: "0", count: -position) + digits }
            else if position >= digits.count { result = digits + String(repeating: "0", count: position - digits.count) }
            else { let split = digits.index(digits.startIndex, offsetBy: position); result = String(digits[..<split]) + "." + String(digits[split...]) }
        } else {
            result = String(digits.prefix(1)) + (digits.count == 1 ? "" : "." + String(digits.dropFirst())) + "e" + (power >= 0 ? "+" : "") + String(power)
        }
        if negative { result = "-" + result }; return Data(result.utf8)
    }
    private static func quote(_ value: String) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]; return try encoder.encode(value)
    }
}

/// Quenderin Host companion v1. Exact event-provided scope is checked by both
/// native coordinator and Host; legacy $events/result remains blocked.
public struct RemoteHarnessApprovalBinding: Sendable, Equatable, NativeConnectionPrivateValue {
    public let hostDeviceID: String
    public let clientDeviceID: String
    public let workspaceID: String
    public let sessionID: String
    public let runID: String
    public let eventID: String
    public let actionDigest: String
    public let expiresAt: Int64
    public init(_ value: RemoteHarnessJSON) throws {
        let f = try value.fields()
        try f.requireKeys(["hostDeviceId", "clientDeviceId", "workspaceId", "sessionId", "runId", "eventId", "actionDigest", "expiresAt"])
        hostDeviceID = try f.text("hostDeviceId"); clientDeviceID = try f.text("clientDeviceId"); workspaceID = try f.text("workspaceId")
        sessionID = try f.text("sessionId"); runID = try f.text("runId"); eventID = try f.text("eventId"); actionDigest = try f.text("actionDigest")
        expiresAt = try f.required("expiresAt").integerValue()
        for id in [hostDeviceID, clientDeviceID, workspaceID, sessionID, runID, eventID] { guard !id.isEmpty, id.utf8.count <= 1024, !id.contains("\0") else { throw RemoteHarnessError.invalidMessage } }
        guard actionDigest.utf8.count == 64, actionDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RemoteHarnessError.invalidMessage }
    }
    public func json() throws -> RemoteHarnessJSON {
        try .object(["hostDeviceId": .string(hostDeviceID), "clientDeviceId": .string(clientDeviceID), "workspaceId": .string(workspaceID), "sessionId": .string(sessionID),
            "runId": .string(runID), "eventId": .string(eventID), "actionDigest": .string(actionDigest), "expiresAt": .integer(expiresAt)])
    }
    func matches(_ binding: RemoteHarnessBinding, referenceTime: Int64) -> Bool {
        guard referenceTime > 0, referenceTime <= NativeConnectionBounds.counter, expiresAt > referenceTime, expiresAt <= NativeConnectionBounds.counter else { return false }
        func equal(_ a: String, _ b: String?) -> Bool { b.map { a.utf8.elementsEqual($0.utf8) } ?? false }
        return equal(hostDeviceID, binding.hostID) && equal(clientDeviceID, binding.clientDeviceID) && equal(workspaceID, binding.workspaceID) && equal(sessionID, binding.sessionID)
            && expiresAt - referenceTime <= 120_000
    }
    func exactlyMatches(_ other: Self) -> Bool {
        zip([hostDeviceID, clientDeviceID, workspaceID, sessionID, runID, eventID, actionDigest],
            [other.hostDeviceID, other.clientDeviceID, other.workspaceID, other.sessionID, other.runID, other.eventID, other.actionDigest])
            .allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) } && expiresAt == other.expiresAt
    }
}
