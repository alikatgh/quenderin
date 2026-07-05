import Foundation

/// The agent's WORKSPACE: one folder the user explicitly granted (folder picker — never a
/// model-minted path), inside which the "operate the computer" capabilities work. One folder
/// at a time ON PURPOSE: a small local model reasoning about one bounded directory is
/// predictable; a grab-bag of grants is where mistakes hide. Granting a new folder replaces
/// the old grant (and its security scope).
public final class WorkspaceStore: ObservableObject, @unchecked Sendable {
    public static let shared = WorkspaceStore()

    private let lock = NSLock()
    private var folder: URL?
    /// Main-thread mirror for SwiftUI (the workspace chip).
    @Published public private(set) var folderName: String?

    public init() {}

    public func grant(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        lock.lock()
        let previous = folder
        folder = url
        lock.unlock()
        previous?.stopAccessingSecurityScopedResource()
        publish(url.lastPathComponent)
    }

    public func revoke() {
        lock.lock()
        let previous = folder
        folder = nil
        lock.unlock()
        previous?.stopAccessingSecurityScopedResource()
        publish(nil)
    }

    public func snapshot() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return folder
    }

    private func publish(_ name: String?) {
        if Thread.isMainThread { folderName = name } else { DispatchQueue.main.async { self.folderName = name } }
    }
}

/// T1: list the workspace folder — names, kinds, sizes. The perception half of "organize this
/// folder for me". Read-only; input is ignored (ONE workspace, no path arguments a model could
/// get creative with).
public struct FileListCapability: Capability {
    public let name = "fs.list"
    public let purpose = "List the files in the workspace folder the user granted. Takes no input."
    public let tier: CapabilityTier = .readOnly
    public let blastRadius: BlastRadius = .read(resource: "the workspace folder")

    private let workspace: @Sendable () -> URL?

    public init(workspace: @escaping @Sendable () -> URL?) {
        self.workspace = workspace
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard let folder = workspace() else {
            return ActionPreview(summary: "Nothing to list: no workspace folder granted yet.", mutates: false)
        }
        return ActionPreview(summary: "Would list the contents of \"\(folder.lastPathComponent)\". Read-only.", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard let folder = workspace() else {
            return "No workspace folder granted. Ask the user to grant one (folder button on the Agent screen)."
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else {
            return "Couldn't list \"\(folder.lastPathComponent)\" — it may have been moved or deleted."
        }
        let visible = names.filter { !$0.hasPrefix(".") }.sorted()
        guard !visible.isEmpty else { return "The workspace \"\(folder.lastPathComponent)\" is empty." }
        let lines = visible.prefix(200).map { name -> String in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDir)
            return isDir.boolValue ? "\(name)/" : name
        }
        let truncated = visible.count > 200 ? "\n[…\(visible.count - 200) more]" : ""
        return lines.joined(separator: "\n") + truncated
    }
}

/// A reversal recipe for every workspace write — the "undoable" in "reversible write". One
/// entry per executed move, newest last; `undoLast()` plays the inverse. In-memory per session
/// for now (the files themselves are the durable state; the ledger is the durable RECORD).
public final class UndoJournal: @unchecked Sendable {
    public struct Entry: Equatable {
        public let from: URL   // where the file was
        public let to: URL     // where it is now
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    public init() {}

    public func record(from: URL, to: URL) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(from: from, to: to))
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Reverse the most recent move. Returns a human sentence either way — surfaced in the UI.
    public func undoLast() -> String {
        lock.lock()
        guard let last = entries.popLast() else {
            lock.unlock()
            return "Nothing to undo."
        }
        lock.unlock()
        do {
            try FileManager.default.moveItem(at: last.to, to: last.from)
            return "Moved \"\(last.to.lastPathComponent)\" back to where it was."
        } catch {
            return "Couldn't undo the last move: \(error.localizedDescription)"
        }
    }
}

/// T2 — the FIRST write capability: move a file inside the workspace. Every safety property
/// is structural, not behavioral:
///   input   — "«file» to «subfolder»", both resolved INSIDE the workspace (no paths, no "..")
///   consent — tier > T0 ⇒ the user must have granted fs.move in Settings
///   approval— blastRadius.mutates ⇒ the runner demands per-RUN approval (fail-closed)
///   no loss — never overwrites; destination collisions are refused
///   undo    — every executed move is recorded in the UndoJournal
public struct FileMoveCapability: Capability {
    public let name = "fs.move"
    public let purpose = "Move a file into a subfolder of the workspace. Input: \"<file name> to <subfolder name>\"."
    public let tier: CapabilityTier = .reversibleWrite
    public let blastRadius: BlastRadius = .write(resource: "the workspace folder")

    private let workspace: @Sendable () -> URL?
    private let journal: UndoJournal

    public init(workspace: @escaping @Sendable () -> URL?, journal: UndoJournal) {
        self.workspace = workspace
        self.journal = journal
    }

    /// Parse "«file» to «subfolder»" and resolve both inside the workspace. Deterministic and
    /// strict: a name with a path separator or ".." is rejected outright — the model names
    /// things the user can see in fs.list; it never navigates.
    private enum Resolution {
        case ok(file: URL, destDir: URL, fileName: String, destName: String)
        case fail(String)
    }

    private func resolve(_ input: String) -> Resolution {
        guard let folder = workspace() else {
            return .fail("No workspace folder granted. Ask the user to grant one first.")
        }
        let parts = input.components(separatedBy: " to ")
        guard parts.count == 2 else {
            return .fail("Input must be \"<file name> to <subfolder name>\", e.g. \"report.pdf to Archive\".")
        }
        let fileName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let destName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        for name in [fileName, destName] where name.isEmpty || name.contains("/") || name.contains("..") {
            return .fail("File and folder are plain names inside the workspace — paths aren't allowed.")
        }
        let file = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .fail("No file named \"\(fileName)\" in the workspace. Use fs.list to see what's there.")
        }
        return .ok(file: file, destDir: folder.appendingPathComponent(destName), fileName: fileName, destName: destName)
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        switch resolve(input) {
        case .fail(let reason):
            return ActionPreview(summary: reason, mutates: false)
        case .ok(let file, let destDir, let fileName, let destName):
            return ActionPreview(
                summary: "Move \"\(fileName)\" into \"\(destName)/\" (inside the workspace; undoable).",
                mutates: true
            )
        }
    }

    public func run(_ input: String) async throws -> String {
        switch resolve(input) {
        case .fail(let reason):
            return reason
        case .ok(let file, let destDir, let fileName, let destName):
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: destDir.path, isDirectory: &isDir) {
                guard isDir.boolValue else { return "\"\(destName)\" is a file, not a folder." }
            } else {
                do { try fm.createDirectory(at: destDir, withIntermediateDirectories: false) }
                catch { return "Couldn't create \"\(destName)/\": \(error.localizedDescription)" }
            }
            let target = destDir.appendingPathComponent(fileName)
            // Never overwrite — reversible means no data is ever lost, including at the target.
            guard !fm.fileExists(atPath: target.path) else {
                return "\"\(destName)/\(fileName)\" already exists — refusing to overwrite."
            }
            do {
                try fm.moveItem(at: file, to: target)
            } catch {
                return "Couldn't move \"\(fileName)\": \(error.localizedDescription)"
            }
            journal.record(from: file, to: target)
            return "Moved \"\(fileName)\" into \"\(destName)/\". (Undo is available.)"
        }
    }
}
