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

/// T2: rename a file inside the workspace — same spine as fs.move (plain names, no overwrite,
/// journal-recorded so Undo restores the old name).
public struct FileRenameCapability: VerifiableCapability {
    public let name = "fs.rename"
    public let purpose = "Rename a file in the workspace. Input: \"<current name> to <new name>\"."
    public let tier: CapabilityTier = .reversibleWrite
    public let blastRadius: BlastRadius = .write(resource: "the workspace folder")

    private let workspace: @Sendable () -> URL?
    private let journal: UndoJournal

    public init(workspace: @escaping @Sendable () -> URL?, journal: UndoJournal) {
        self.workspace = workspace
        self.journal = journal
    }

    private func resolve(_ input: String) -> (from: URL, to: URL, fromName: String, toName: String)? {
        guard let folder = workspace() else { return nil }
        let parts = input.components(separatedBy: " to ")
        guard parts.count == 2 else { return nil }
        let fromName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let toName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        for name in [fromName, toName] where name.isEmpty || name.contains("/") || name.contains("..") { return nil }
        return (folder.appendingPathComponent(fromName), folder.appendingPathComponent(toName), fromName, toName)
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard workspace() != nil else {
            return ActionPreview(summary: "No workspace folder granted. Ask the user to grant one first.", mutates: false)
        }
        guard let r = resolve(input), FileManager.default.fileExists(atPath: r.from.path) else {
            return ActionPreview(summary: "Input must be \"<current name> to <new name>\", both plain names of workspace files.", mutates: false)
        }
        return ActionPreview(summary: "Rename \"\(r.fromName)\" to \"\(r.toName)\" (inside the workspace; undoable).", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard workspace() != nil else { return "No workspace folder granted. Ask the user to grant one first." }
        guard let r = resolve(input) else {
            return "Input must be \"<current name> to <new name>\" — plain names, no paths."
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: r.from.path) else {
            return "No file named \"\(r.fromName)\" in the workspace. Use fs.list to see what's there."
        }
        guard !fm.fileExists(atPath: r.to.path) else {
            return "\"\(r.toName)\" already exists — refusing to overwrite."
        }
        do { try fm.moveItem(at: r.from, to: r.to) } catch {
            return "Couldn't rename \"\(r.fromName)\": \(error.localizedDescription)"
        }
        journal.record(from: r.from, to: r.to)
        return "Renamed \"\(r.fromName)\" to \"\(r.toName)\". (Undo is available.)"
    }

    public func verify(_ input: String) async -> (ok: Bool, detail: String) {
        // Parse shape only — after a rename the old name is gone by design.
        guard let folder = workspace() else { return (false, "No workspace.") }
        let parts = input.components(separatedBy: " to ")
        guard parts.count == 2 else { return (false, "Bad input for verify.") }
        let fromName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let toName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        for name in [fromName, toName] where name.isEmpty || name.contains("/") || name.contains("..") {
            return (false, "Bad input for verify.")
        }
        let from = folder.appendingPathComponent(fromName)
        let to = folder.appendingPathComponent(toName)
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path), !fm.fileExists(atPath: from.path) {
            return (true, "\"\(toName)\" is in place.")
        }
        return (false, "Rename to \"\(toName)\" did not land.")
    }
}

/// T2: move a file into the workspace's visible "Trash" subfolder — deliberately NOT the system
/// trash: identical, predictable semantics on every platform, in plain sight, and Undo moves it
/// straight back. Sugar over the fs.move spine for the model's most common cleanup verb.
public struct FileTrashCapability: Capability {
    public let name = "fs.trash"
    public let purpose = "Move a file into the workspace's Trash folder. Input: \"<file name>\"."
    public let tier: CapabilityTier = .reversibleWrite
    public let blastRadius: BlastRadius = .write(resource: "the workspace folder")

    private let workspace: @Sendable () -> URL?
    private let journal: UndoJournal

    public init(workspace: @escaping @Sendable () -> URL?, journal: UndoJournal) {
        self.workspace = workspace
        self.journal = journal
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workspace() != nil, !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            return ActionPreview(summary: "Input is one plain file name from the workspace.", mutates: false)
        }
        return ActionPreview(summary: "Move \"\(name)\" into the workspace's Trash/ folder (undoable — not deleted).", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard let folder = workspace() else { return "No workspace folder granted. Ask the user to grant one first." }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            return "Input is one plain file name — no paths."
        }
        let file = folder.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            return "No file named \"\(name)\" in the workspace. Use fs.list to see what's there."
        }
        let trashDir = folder.appendingPathComponent("Trash")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: trashDir.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return "\"Trash\" is a file, not a folder." }
        } else {
            do { try fm.createDirectory(at: trashDir, withIntermediateDirectories: false) }
            catch { return "Couldn't create Trash/: \(error.localizedDescription)" }
        }
        let target = trashDir.appendingPathComponent(name)
        guard !fm.fileExists(atPath: target.path) else {
            return "Trash/\(name) already exists — refusing to overwrite."
        }
        do { try fm.moveItem(at: file, to: target) } catch {
            return "Couldn't trash \"\(name)\": \(error.localizedDescription)"
        }
        journal.record(from: file, to: target)
        return "Moved \"\(name)\" to Trash/. (Undo restores it; nothing is deleted.)"
    }
}

/// T2 — the FIRST write capability: move a file inside the workspace. Every safety property
/// is structural, not behavioral:
///   input   — "«file» to «subfolder»", both resolved INSIDE the workspace (no paths, no "..")
///   consent — tier > T0 ⇒ the user must have granted fs.move in Settings
///   approval— blastRadius.mutates ⇒ the runner demands per-RUN approval (fail-closed)
///   no loss — never overwrites; destination collisions are refused
///   undo    — every executed move is recorded in the UndoJournal
public struct FileMoveCapability: VerifiableCapability {
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

    /// Shape-only parse (no existence check). Used by verify() AFTER a move — the source is
    /// gone by design, so resolve()'s existence guard would false-fail every successful move.
    private func parse(_ input: String) -> (folder: URL, file: URL, destDir: URL, fileName: String, destName: String)? {
        guard let folder = workspace() else { return nil }
        let parts = input.components(separatedBy: " to ")
        guard parts.count == 2 else { return nil }
        let fileName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let destName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        for name in [fileName, destName] where name.isEmpty || name.contains("/") || name.contains("..") { return nil }
        return (folder, folder.appendingPathComponent(fileName), folder.appendingPathComponent(destName), fileName, destName)
    }

    private func resolve(_ input: String) -> Resolution {
        guard let p = parse(input) else {
            if workspace() == nil {
                return .fail("No workspace folder granted. Ask the user to grant one first.")
            }
            return .fail("Input must be \"<file name> to <subfolder name>\", e.g. \"report.pdf to Archive\".")
        }
        guard FileManager.default.fileExists(atPath: p.file.path) else {
            return .fail("No file named \"\(p.fileName)\" in the workspace. Use fs.list to see what's there.")
        }
        return .ok(file: p.file, destDir: p.destDir, fileName: p.fileName, destName: p.destName)
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

    public func verify(_ input: String) async -> (ok: Bool, detail: String) {
        // parse (not resolve): source is gone after a successful move — existence of source
        // would make every good move look unverified.
        guard let p = parse(input) else {
            return (false, "Bad input for verify.")
        }
        let target = p.destDir.appendingPathComponent(p.fileName)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: p.file.path) {
            return (true, "\"\(p.destName)/\(p.fileName)\" is in place.")
        }
        return (false, "Move of \"\(p.fileName)\" into \"\(p.destName)/\" did not land.")
    }
}
