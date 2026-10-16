import Foundation
import CryptoKit

/// Post-download integrity verification for GGUF model files (audit finding C3).
///
/// The downloader streams multi-GB files from catalog-pinned HTTPS URLs to disk, then hands
/// them to llama.cpp's GGUF parser. A TLS-MITM, a poisoned mirror, or a silently-truncated
/// transfer could substitute or corrupt those bytes. This is the gate between "downloaded"
/// and "loaded": the GGUF magic header is always checked, and when the catalog pins a
/// SHA-256 the whole-file digest must match it. Twin of desktop `modelIntegrity.ts` and
/// Android `ModelIntegrity`.
public enum ModelIntegrityError: Error, Equatable {
    case notGGUF(foundMagic: String)
    case checksumMismatch(expected: String, actual: String)
}

public enum ModelIntegrity {
    /// GGUF files begin with the 4-byte magic "GGUF" (0x47 0x47 0x55 0x46).
    public static let ggufMagic = Data([0x47, 0x47, 0x55, 0x46])

    /// True iff the buffer's first 4 bytes are the GGUF magic header.
    public static func hasGGUFMagic(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == ggufMagic
    }

    /// Streaming SHA-256 of a file (constant memory) → lowercase hex.
    public static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a freshly-downloaded model before it is loaded. Throws `ModelIntegrityError`
    /// on mismatch; the caller should delete the file so a retry re-downloads cleanly. When
    /// `expectedSHA256` is nil/empty only the magic header is checked (still rejects HTML
    /// error pages and truncated files).
    public static func verify(fileURL: URL, expectedSHA256: String?) throws {
        let identityBeforeHash = ModelArtifactReceipts.Identity.read(fileURL)
        let head = try readHead(fileURL, 4)
        guard hasGGUFMagic(head) else {
            throw ModelIntegrityError.notGGUF(foundMagic: head.map { String(format: "%02x", $0) }.joined())
        }
        if let expected = expectedSHA256, !expected.isEmpty {
            let actual = try sha256Hex(of: fileURL)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw ModelIntegrityError.checksumMismatch(expected: expected, actual: actual)
            }
            // The transport has already hashed this file. Reuse that proof during set
            // installation instead of reading hundreds of GB a second time.
            if let before = identityBeforeHash, let after = ModelArtifactReceipts.Identity.read(fileURL), before == after {
                let part = ModelArtifact(filename: fileURL.lastPathComponent, url: "", sha256: actual, downloadBytes: after.size)
                ModelArtifactReceipts.shared.record(part, at: fileURL, identity: after)
            }
        }
    }

    private static func readHead(_ fileURL: URL, _ n: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return (try handle.read(upToCount: n)) ?? Data()
    }
}
