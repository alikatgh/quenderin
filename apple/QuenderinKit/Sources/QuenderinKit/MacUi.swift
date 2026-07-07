import Foundation

/// The macOS GUI-driving seam — read the frontmost app's accessibility tree and click/type into ANY
/// app, not just the AppleScript-scriptable ones. This is the "screen → click" leap that makes the
/// agent operate a Mac like a person rather than only scripting the ~9 apps with AppleScript
/// dictionaries. Ported 1:1 from the desktop lab's `src/services/capability/macUi.ts`: an interface
/// with a production implementation over macOS System Events (accessibility) and a fake for tests, so
/// the capability LOGIC (resolve-by-label, blocklist re-check) is fully verifiable headless while the
/// one production-only surface is the osascript bridge — exactly like every other mac.* capability.
public struct MacUiElement: Sendable, Equatable {
    /// The accessibility name (AXTitle/label) the user sees — the model targets THIS, never a pixel.
    public let label: String
    /// The AX role, e.g. "button", "menu item", "text field" — shown for context + disambiguation.
    public let role: String
    public init(label: String, role: String) {
        self.label = label
        self.role = role
    }
}

public protocol MacUi: Sendable {
    var available: Bool { get }
    /// The named, actionable elements of the frontmost app's window.
    func observe() async throws -> [MacUiElement]
    /// Click the (unique) element with this accessibility name.
    func click(_ label: String) async throws
    /// Type text into whatever is focused.
    func typeText(_ text: String) async throws
    /// Press a whitelisted navigation key: return, tab, escape, up, down, left, right, pageup, pagedown.
    func pressKey(_ key: String) async throws
    /// Click a menu-bar path, e.g. ["File", "Save As"] — the menu bar is a separate AX hierarchy.
    func clickMenu(_ path: [String]) async throws
}

#if os(macOS)
/// macOS System Events implementation. The production-only bridge (needs Accessibility permission);
/// built ON TOP of the hardened `MacAutomation` runner so escaping + execFile safety are reused —
/// the twin of the TS `OsascriptMacUi`, template for template.
public final class OsascriptMacUi: MacUi {
    private let mac: any MacAutomation
    public init(mac: any MacAutomation) { self.mac = mac }

    public var available: Bool { mac.available }

    public func observe() async throws -> [MacUiElement] {
        // Walk the front window's elements, emitting "role\tname" for each named one. `entire
        // contents` reaches nested elements; capped by the capability. Best-effort per element.
        let script = [
            "set out to \"\"",
            "tell application \"System Events\"",
            "  set frontProc to first application process whose frontmost is true",
            "  tell frontProc",
            "    try",
            "      set els to entire contents of front window",
            "    on error",
            "      set els to UI elements",
            "    end try",
            "    repeat with e in els",
            "      try",
            "        set n to name of e",
            "        if n is not missing value and n is not \"\" then set out to out & (role of e) & tab & n & linefeed",
            "      end try",
            "    end repeat",
            "  end tell",
            "end tell",
            "return out",
        ].joined(separator: "\n")
        let raw = try await mac.runAppleScript(script)
        // Split on the FIRST tab only, so a label that itself contains a tab is preserved intact
        // (role is always a single token) rather than silently dropped.
        var out: [MacUiElement] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let i = line.firstIndex(of: "\t") else { continue }
            let role = String(line[line.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            let label = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { out.append(MacUiElement(label: label, role: role)) }
        }
        return out
    }

    public func click(_ label: String) async throws {
        let esc = escapeAppleScriptString(label)
        let script = [
            "tell application \"System Events\"",
            "  tell (first application process whose frontmost is true)",
            "    try",
            "      set target to first UI element of entire contents of front window whose name is \"\(esc)\"",
            "    on error",
            "      set target to first UI element whose name is \"\(esc)\"",
            "    end try",
            "    click target",
            "  end tell",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        _ = try await mac.runAppleScript(script)
    }

    public func typeText(_ text: String) async throws {
        _ = try await mac.runAppleScript("tell application \"System Events\" to keystroke \"\(escapeAppleScriptString(text))\"")
    }

    public func clickMenu(_ path: [String]) async throws {
        // Support ANY depth, not just two levels. macOS nests submenus as
        //   menu item "Bold" of menu "Font" of menu item "Font" of menu "Format" of menu bar 1
        // i.e. the last element is a `menu item`, then each earlier level adds `of menu "X"` and
        // (unless it's the top menu bar) `of menu item "X"`. (Twin of the TS clickMenu, Q-279.)
        let esc = path.map(escapeAppleScriptString)
        var ref = "menu item \"\(esc[esc.count - 1])\""
        var i = esc.count - 2
        while i >= 0 {
            ref += " of menu \"\(esc[i])\""
            if i > 0 { ref += " of menu item \"\(esc[i])\"" }
            i -= 1
        }
        ref += " of menu bar 1"
        let script = [
            "tell application \"System Events\"",
            "  tell (first application process whose frontmost is true)",
            "    click \(ref)",
            "  end tell",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        _ = try await mac.runAppleScript(script)
    }

    public func pressKey(_ key: String) async throws {
        // Navigation + confirm/dismiss keys — enough to move through lists and scroll panes, never a
        // character key (that's mac.ui.type) and never a destructive shortcut.
        let codes: [String: Int] = [
            "return": 36, "tab": 48, "escape": 53,
            "up": 126, "down": 125, "left": 123, "right": 124, "pageup": 116, "pagedown": 121,
        ]
        guard let code = codes[key] else { throw MacAutomationError.script(message: "unsupported key: \(key)") }
        _ = try await mac.runAppleScript("tell application \"System Events\" to key code \(code)")
    }
}
#endif
