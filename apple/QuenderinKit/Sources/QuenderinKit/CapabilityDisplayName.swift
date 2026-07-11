import Foundation

/// Human-friendly names for the agent's capabilities. The tool *id* (`mac.ui.tap`) is a stable
/// identifier the model emits, the consent store keys on, and the ledger records — it must never
/// change. But a PERSON reading the Settings list shouldn't have to parse `mac.reminders.add`; they
/// should see "Add a reminder". This is the presentation layer that maps id → friendly name, kept in
/// ONE place so every surface (Settings today, run log / approval dialog later) shows the same words.
///
/// A capability without an explicit entry falls back to a prettified id so it still reads acceptably —
/// but `CapabilityDisplayNameTests` asserts every SHIPPED capability has a real entry, so the fallback
/// is only ever a safety net, never the shipped experience.
public enum CapabilityCatalog {
    public static let displayNames: [String: String] = [
        // Pure compute
        "calculator": "Calculator",
        "units": "Convert units",
        "date": "Date math",
        // Files (the granted workspace)
        "fs.read": "Read a file",
        "fs.list": "List files",
        "fs.move": "Move a file",
        "fs.rename": "Rename a file",
        "fs.trash": "Move a file to Trash",
        // macOS perception (read-only)
        "mac.frontApp": "See the active app",
        "mac.clipboard.read": "Read the clipboard",
        "mac.calendar.today": "See today’s calendar",
        "mac.shortcuts.list": "List your Shortcuts",
        "mac.finder.reveal": "Show a file in Finder",
        // macOS actions
        "mac.app.open": "Open an app",
        "mac.safari.openURL": "Open a web page",
        "mac.notes.create": "Create a note",
        "mac.reminders.add": "Add a reminder",
        "mac.calendar.add": "Add a calendar event",
        "mac.mail.draft": "Draft an email",
        "mac.shortcuts.run": "Run a Shortcut",
        // macOS GUI driving (the accessibility tree)
        "mac.ui.observe": "See what’s on screen",
        "mac.ui.tap": "Click a button",
        "mac.ui.type": "Type text",
        "mac.ui.key": "Press a key",
        "mac.ui.menu": "Use a menu",
        // iOS device perception twins
        "device.clipboard.read": "Read the clipboard",
        "device.calendar.today": "See today’s calendar",
        "device.status": "Check battery & storage",
    ]

    /// The friendly name for a capability id — an explicit entry, else a prettified id.
    public static func displayName(for id: String) -> String {
        // Localized at lookup: the English map value doubles as the catalog key
        // (Localizable.xcstrings in the app bundle carries ru/ko/ja/zh-Hans).
        guard let name = displayNames[id] else { return prettify(id) }
        return String(localized: String.LocalizationValue(name))
    }

    /// Turn `some.new_tool` into "Some New Tool" — a graceful fallback for an unmapped id so a newly
    /// added capability never shows a raw dotted id to a user before its real name is filled in.
    static func prettify(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
