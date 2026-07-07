import Foundation
import Combine

/// The user's attached files — THE ONLY source that populates `fs.read`'s granted map
/// (AGENT_AUTONOMY_PLAN §7: files enter by explicit user pick, never by model output).
/// UI mutations happen on the main thread ( fileImporter callbacks / chip removes); the
/// agent reads `snapshot()` from its async context, so the map itself is lock-protected.
public final class AttachedFilesStore: ObservableObject, @unchecked Sendable {
    /// One process-wide store: the Agent screen attaches, the capability reads.
    public static let shared = AttachedFilesStore()

    private let lock = NSLock()
    private var files: [String: URL] = [:]
    /// Main-thread mirror for SwiftUI (chips row) — kept in insertion order.
    @Published public private(set) var names: [String] = []

    public init() {}

    /// Attach a user-picked file. Name collisions get a numeric suffix so two picks named
    /// "notes.txt" stay distinguishable and neither silently replaces the other.
    /// Starts security-scoped access (needed to read the pick later inside the iOS sandbox;
    /// harmless on macOS) — released on remove.
    public func attach(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        lock.lock()
        var name = url.lastPathComponent
        var counter = 2
        while files[name] != nil {
            name = "\(url.deletingPathExtension().lastPathComponent) (\(counter)).\(url.pathExtension)"
            counter += 1
        }
        files[name] = url
        let updated = orderedNames()
        lock.unlock()
        publish(updated)
    }

    public func remove(_ name: String) {
        lock.lock()
        let url = files.removeValue(forKey: name)
        let updated = orderedNames()
        lock.unlock()
        url?.stopAccessingSecurityScopedResource()
        publish(updated)
    }

    /// What the agent may read right now — lock-protected, safe from any context.
    public func snapshot() -> [String: URL] {
        lock.lock(); defer { lock.unlock() }
        return files
    }

    private func orderedNames() -> [String] { files.keys.sorted() }

    private func publish(_ updated: [String]) {
        if Thread.isMainThread {
            names = updated
        } else {
            DispatchQueue.main.async { self.names = updated }
        }
    }
}

/// The app's standard agent toolkit — ONE place that says which capabilities ship, consumed by
/// both the app target (AgentSession tools) and the Settings capabilities pane, so the pane can
/// never drift from what the agent actually has.
public enum AgentToolkit {
    /// The session-wide undo journal for workspace writes — the Agent screen's "Undo last move"
    /// reverses through it.
    public static let undoJournal = UndoJournal()

    public static func standard(attachments: AttachedFilesStore = .shared,
                                workspace: WorkspaceStore = .shared) -> [AgentTool] {
        var tools: [AgentTool] = [
            CalculatorTool(),
            UnitConverterTool(),
            DateCalcTool(),
            // EchoTool is deliberately NOT shipped: it's a dev/demo tool, and weak models grab it
            // as a scratchpad — a live mission burned its first two steps echoing an email address
            // before attempting the real work. Tests that need it construct it directly.
            FileReadCapability(grantedFiles: { attachments.snapshot() }),
            FileListCapability(workspace: { workspace.snapshot() }),
            FileMoveCapability(workspace: { workspace.snapshot() }, journal: undoJournal),
            FileRenameCapability(workspace: { workspace.snapshot() }, journal: undoJournal),
            FileTrashCapability(workspace: { workspace.snapshot() }, journal: undoJournal),
        ]
        #if os(macOS)
        // The native mac.* library (H1: the macOS product is the Swift app) — the same governed
        // spine gates them: T1 needs consent, T2/T3 additionally per-run approval via the Agent
        // screen's dialog, every action ledgered. The Settings pane picks these up automatically
        // because it reads THIS list.
        let mac = OsascriptAutomation()
        tools += macCapabilities(mac: mac).map { $0 as AgentTool }
        // GUI-driving (mac.ui.*) rides the SAME osascript seam — click/type/menu into ANY app via the
        // accessibility tree, not just the AppleScript-scriptable ones ("screen → click"). The model
        // taps by visible label (never a fabricated pixel); the same spine gates every action.
        tools += macUiCapabilities(ui: OsascriptMacUi(mac: mac)).map { $0 as AgentTool }
        #else
        // T1 device PERCEPTION on the phone (owner sign-off 2026-07-07; PRODUCT.md revised):
        // clipboard + today's calendar, read-only, consent-gated — the senses macOS gets from
        // its mac.* twins above, provided natively here.
        tools.append(DeviceClipboardReadCapability())
        #if canImport(EventKit)
        tools.append(CalendarTodayDeviceCapability(reader: EventKitCalendarReader()))
        #endif
        #endif
        // Battery + free storage — "can this device even do that?" — useful on every platform.
        tools.append(DeviceStatusCapability())
        return tools
    }

    /// The toolkit's capabilities in display order (everything we ship IS a capability today).
    public static func capabilities(attachments: AttachedFilesStore = .shared,
                                    workspace: WorkspaceStore = .shared) -> [any Capability] {
        standard(attachments: attachments, workspace: workspace).compactMap { $0 as? any Capability }
    }
}
