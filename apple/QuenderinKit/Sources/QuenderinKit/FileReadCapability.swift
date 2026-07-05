import Foundation

/// The first real T1 capability (AGENT_AUTONOMY_PLAN Milestone 0, step 3): read a text file the
/// USER selected. The security property lives in the `grantedFiles` seam — only files the user
/// explicitly picked (file dialog / attach UI) ever enter that map, so the model can NAME a
/// granted file but can never mint a path. A path in LLM output is not a grant (§7: "never a
/// path from LLM output"). Read-only, size-capped, consent-gated by tier. Twin of Kotlin
/// `FileReadCapability`.
public struct FileReadCapability: Capability {
    public let name = "fs.read"
    public let purpose = "Read a text file the user has attached, by its name. Only user-attached files are readable."
    public let tier: CapabilityTier = .readOnly
    public let blastRadius: BlastRadius = .read(resource: "a file you selected")

    /// User-granted files: display name → location. Populated ONLY by user file-picks.
    private let grantedFiles: @Sendable () -> [String: URL]
    /// Cap what one read can pull into the context (64 KB default) — a T1 read must not become
    /// a memory/context hog by way of a giant file.
    private let maxBytes: Int

    public init(grantedFiles: @escaping @Sendable () -> [String: URL], maxBytes: Int = 64 * 1024) {
        self.grantedFiles = grantedFiles
        self.maxBytes = maxBytes
    }

    /// Resolve the model's requested name against the granted map: exact, then case-insensitive.
    /// Deliberately NO fuzzy matching — a T1 resource lookup must be predictable, not clever.
    private func resolve(_ requested: String) -> (name: String, url: URL)? {
        let files = grantedFiles()
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = files[trimmed] { return (trimmed, url) }
        if let match = files.first(where: { $0.key.lowercased() == trimmed.lowercased() }) {
            return (match.key, match.value)
        }
        return nil
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard let (name, url) = resolve(input) else {
            return ActionPreview(summary: "Nothing to read: no attached file named \"\(input)\". The user must attach it first.", mutates: false)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let sizeNote = size.map { " (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" } ?? ""
        return ActionPreview(summary: "Would read the attached file \"\(name)\"\(sizeNote). Read-only.", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard let (name, url) = resolve(input) else {
            let available = grantedFiles().keys.sorted().joined(separator: ", ")
            return available.isEmpty
                ? "No files are attached. Ask the user to attach the file first."
                : "No attached file named \"\(input)\". Attached files: \(available)."
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "Couldn't open \"\(name)\" — it may have been moved or deleted."
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else {
            return "Couldn't read \"\(name)\"."
        }
        let truncated = data.count > maxBytes
        guard let text = String(data: truncated ? data.prefix(maxBytes) : data, encoding: .utf8) else {
            return "\"\(name)\" isn't a text file (or isn't UTF-8) — fs.read only reads text."
        }
        return truncated ? text + "\n[…truncated at \(maxBytes / 1024) KB]" : text
    }
}
