import Foundation

/// Explicit `data` access is a private-data export. Logs and reflected dumps are redacted.
public struct RemoteHarnessFragmentBytes: Sendable, Equatable, NativeConnectionPrivateValue {
    public let data: Data
    fileprivate init(_ data: Data) { self.data = data }
}

public enum RemoteHarnessFragmentError: String, Error, Sendable, CustomStringConvertible {
    case initialState, generation, retired, counterExhausted, messageLimit, reservedPrefix
    case clock, expired, frameLimit, rawLimit, header, metadata, length, sequence, assemblyLimit, idLimit
    public var description: String { "Remote Harness fragment: \(rawValue)" }
}

/// Source-only DSHF plaintext framing around the maintained Noise facade; no transport or crypto.
/// Protocol facts: liguobao/ds-harness-remote@9a60e783ec1ceaff6116b0462a2863f07f602a55,
/// packages/protocol/src/index.ts SecureMessageCodec.
///
/// The authenticated owner serializes sends, calls `checkExpiry` from its idle timer and
/// retires the codec on disconnect. Active-generation errors retire and clear all state:
/// close that authenticated connection, do not skip the rejected frame. Reset is permitted
/// only for a NEW authenticated generation. Generation comes from the owner, never wire
/// bytes. A stale-generation call cannot disturb the replacement connection.
@MainActor public final class RemoteHarnessFragments: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let chunkBytes = 49_152
    public static let headerBytes = 17
    public static let messageBytes = 4_194_304
    public static let assemblies = 8
    public static let declaredBytes = 8_388_608
    public static let maxReceivedIDs = 4_096
    public static let deadlineMilliseconds: Int64 = 120_000
    private static let magic: [UInt8] = [0x44, 0x53, 0x48, 0x46]
    private static let maxMessageID: UInt64 = 0xffff_ffff

    private struct Assembly {
        let total: Int
        let byteCount: Int
        let startedAt: Int64
        var nextIndex = 0
        var data = Data()
    }
    private var generation: UInt64
    private var nextMessageID: UInt64
    private var receivedIDs: Set<UInt64> = []
    private var lastMonotonic: Int64?
    private var pending: [UInt64: Assembly] = [:]
    public private(set) var declaredByteCount = 0
    public private(set) var isRetired = false
    public var assemblyCount: Int { pending.count }
    public nonisolated var description: String { "RemoteHarnessFragments(redacted)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }

    public convenience init(authenticatedGeneration: UInt64) throws {
        try self.init(authenticatedGeneration: authenticatedGeneration, initialMessageID: 1)
    }
    // Internal seam exercises exhaustion without allocating billions of messages.
    init(authenticatedGeneration: UInt64, initialMessageID: UInt64) throws {
        guard authenticatedGeneration > 0, authenticatedGeneration <= UInt64(Int64.max),
              (1...Self.maxMessageID).contains(initialMessageID) else { throw RemoteHarnessFragmentError.initialState }
        generation = authenticatedGeneration; nextMessageID = initialMessageID
    }
    public func retire(authenticatedGeneration: UInt64) throws {
        guard authenticatedGeneration == generation else { throw RemoteHarnessFragmentError.generation }
        retireActiveGeneration()
    }
    private func retireActiveGeneration() { pending.removeAll(); receivedIDs.removeAll(); declaredByteCount = 0; isRetired = true }
    public func reset(newAuthenticatedGeneration: UInt64) throws {
        guard newAuthenticatedGeneration > generation, newAuthenticatedGeneration <= UInt64(Int64.max) else { throw RemoteHarnessFragmentError.generation }
        pending.removeAll(); declaredByteCount = 0; generation = newAuthenticatedGeneration
        nextMessageID = 1; receivedIDs.removeAll(); lastMonotonic = nil; isRetired = false
    }
    private func requireGeneration(_ authenticatedGeneration: UInt64) throws {
        guard authenticatedGeneration == generation else { throw RemoteHarnessFragmentError.generation }
        guard !isRetired else { throw RemoteHarnessFragmentError.retired }
    }
    private func requireFrame(_ valid: Bool, _ error: RemoteHarnessFragmentError) throws {
        if !valid { retireActiveGeneration(); throw error }
    }
    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    public func encode(_ message: Data, authenticatedGeneration: UInt64) throws -> [RemoteHarnessFragmentBytes] {
        try requireGeneration(authenticatedGeneration)
        try requireFrame(nextMessageID <= Self.maxMessageID, .counterExhausted)
        try requireFrame(message.count <= Self.messageBytes, .messageLimit)
        if message.count <= Self.chunkBytes {
            // The upstream raw format reserves DSHF for headers; this prefix is ambiguous.
            try requireFrame(!message.starts(with: Self.magic), .reservedPrefix)
            return [RemoteHarnessFragmentBytes(message)]
        }
        let id = nextMessageID; nextMessageID += 1
        let total = (message.count + Self.chunkBytes - 1) / Self.chunkBytes
        var frames: [RemoteHarnessFragmentBytes] = []; frames.reserveCapacity(total)
        for index in 0..<total {
            let start = message.startIndex + index * Self.chunkBytes
            let end = min(message.endIndex, start + Self.chunkBytes)
            var frame = Data(Self.magic); frame.append(1)
            append(UInt32(id), to: &frame); append(UInt16(index), to: &frame)
            append(UInt16(total), to: &frame); append(UInt32(message.count), to: &frame)
            frame.append(message[start..<end]); frames.append(RemoteHarnessFragmentBytes(frame))
        }
        return frames
    }

    /// Absolute first-fragment deadline; traffic cannot extend partial-message lifetime.
    public func checkExpiry(authenticatedGeneration: UInt64, monotonicMilliseconds: Int64) throws {
        try requireGeneration(authenticatedGeneration)
        try requireFrame(monotonicMilliseconds >= 0 && (lastMonotonic == nil || monotonicMilliseconds >= lastMonotonic!), .clock)
        lastMonotonic = monotonicMilliseconds
        try requireFrame(!pending.values.contains { monotonicMilliseconds - $0.startedAt >= Self.deadlineMilliseconds }, .expired)
    }

    /// Takes authenticated DECRYPTED bytes. Nil means incomplete; bytes are never parsed as text.
    public func decode(_ frame: Data, authenticatedGeneration: UInt64, monotonicMilliseconds: Int64) throws -> RemoteHarnessFragmentBytes? {
        try checkExpiry(authenticatedGeneration: authenticatedGeneration, monotonicMilliseconds: monotonicMilliseconds)
        try requireFrame(frame.count <= Self.chunkBytes + Self.headerBytes, .frameLimit)
        if !frame.starts(with: Self.magic) {
            try requireFrame(frame.count <= Self.chunkBytes, .rawLimit)
            return RemoteHarnessFragmentBytes(frame)
        }
        try requireFrame(frame.count >= Self.headerBytes && frame[frame.startIndex + 4] == 1, .header)
        // Foundation's unaligned loads handle Data slices and avoid alignment assumptions.
        let id = frame.withUnsafeBytes { UInt64($0.loadUnaligned(fromByteOffset: 5, as: UInt32.self).bigEndian) }
        let index = frame.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 9, as: UInt16.self).bigEndian) }
        let total = frame.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 11, as: UInt16.self).bigEndian) }
        let bytes = frame.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 13, as: UInt32.self).bigEndian) }
        try requireFrame(id != 0 && bytes > Self.chunkBytes && bytes <= Self.messageBytes && total >= 2 && index < total &&
                         total == (bytes + Self.chunkBytes - 1) / Self.chunkBytes, .metadata)
        let expected = min(Self.chunkBytes, bytes - index * Self.chunkBytes)
        try requireFrame(frame.count - Self.headerBytes == expected, .length)
        if pending[id] == nil {
            try requireFrame(index == 0 && !receivedIDs.contains(id), .sequence)
            try requireFrame(receivedIDs.count < Self.maxReceivedIDs, .idLimit)
            try requireFrame(pending.count < Self.assemblies && bytes <= Self.declaredBytes - declaredByteCount, .assemblyLimit)
            var assembly = Assembly(total: total, byteCount: bytes, startedAt: monotonicMilliseconds)
            assembly.data.reserveCapacity(bytes)
            pending[id] = assembly; declaredByteCount += bytes; receivedIDs.insert(id)
        }
        guard var assembly = pending.removeValue(forKey: id) else { retireActiveGeneration(); throw RemoteHarnessFragmentError.sequence }
        try requireFrame(assembly.total == total && assembly.byteCount == bytes && assembly.nextIndex == index, .sequence)
        assembly.data.append(frame.dropFirst(Self.headerBytes)); assembly.nextIndex += 1
        if assembly.nextIndex < total { pending[id] = assembly; return nil }
        try requireFrame(assembly.data.count == assembly.byteCount, .length)
        declaredByteCount -= assembly.byteCount
        return RemoteHarnessFragmentBytes(assembly.data)
    }
}
