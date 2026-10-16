import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-local proof of a successful streamed hash, invalidated by replacement or mutation.
/// UI refreshes inspect metadata only; they must never hash hundreds of GB on the main actor.
final class ModelArtifactReceipts: @unchecked Sendable {
    static let shared = ModelArtifactReceipts()
    private let lock = NSLock()
    private var verified: [Key: Identity] = [:]

    struct Key: Hashable {
        let path: String
        let hash: String
        let size: Int64
        init(_ part: ModelArtifact, _ url: URL) {
            path = url.standardizedFileURL.path
            hash = part.sha256
            size = part.downloadBytes
        }
    }

    struct Identity: Hashable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(_ url: URL) -> Identity? {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
            #if canImport(Darwin)
            let modified = info.st_mtimespec, changed = info.st_ctimespec
            #else
            let modified = info.st_mtim, changed = info.st_ctim
            #endif
            return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                            modifiedSeconds: Int64(modified.tv_sec), modifiedNanoseconds: Int64(modified.tv_nsec),
                            changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec))
        }
    }

    func contains(_ part: ModelArtifact, at url: URL, identity: Identity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return verified[Key(part, url)] == identity
    }

    func record(_ part: ModelArtifact, at url: URL, identity: Identity) {
        lock.lock(); defer { lock.unlock() }
        // Bound memory even if a caller supplies many different imported manifests.
        if verified.count >= 512 { verified.removeAll(keepingCapacity: true) }
        verified[Key(part, url)] = identity
    }
}
