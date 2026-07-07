import Foundation

/// macOS GUI-driving capabilities — click and type into ANY app via the accessibility tree, not just
/// the AppleScript-scriptable ones. The "screen → click" leap, governed by the same CapabilityRunner
/// spine as everything else (blocklist → consent → preview → per-run approval → ledger, zero new
/// plumbing). Ported 1:1 from the desktop lab's `src/services/capability/macUiCapabilities.ts`.
///
/// The load-bearing safety property: **the model taps by VISIBLE LABEL, never coordinates it makes
/// up** — `mac.ui.tap("Send")` resolves a real named element; a model cannot fabricate a pixel. Every
/// resolved target is re-checked against the blocklist (defense in depth) so an element named "Confirm
/// payment" is refused even after the input string passed. All tap/type/menu/key are T3 → per-run
/// approval.
///
/// Honest gap: the TS `mac.ui.tap` carries a `verify()` ("did the screen change?") — the Swift
/// `Capability` protocol has no verify hook wired into the runner yet, so it's a named follow-up here
/// (same posture as the file-move undo note in MacCapabilities), not silently dropped.

private let uiNoMac = "This runs on macOS only."
private let uiNoPermission = "macOS blocked reading the screen — grant Quenderin Accessibility access in System Settings › Privacy & Security › Accessibility, then try again."

/// T1: read the frontmost app's actionable elements. Perception — consent, no per-run approval.
public struct MacUiObserveCapability: Capability {
    public let name = "mac.ui.observe"
    public let purpose = "List the clickable elements (buttons, menus, fields) of the frontmost macOS app. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "the frontmost app screen")
    private let ui: any MacUi
    public init(ui: any MacUi) { self.ui = ui }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read the frontmost app's on-screen elements (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard ui.available else { return uiNoMac }
        let els: [MacUiElement]
        do { els = try await ui.observe() } catch { return describeUiError(error) }
        if els.isEmpty { return "No named elements on the frontmost window right now." }
        let lines = els.prefix(60).map { "- [\($0.role)] \($0.label)" }
        return lines.joined(separator: "\n") + (els.count > 60 ? "\n[…\(els.count - 60) more]" : "")
    }
}

/// T3: click an element BY ITS VISIBLE LABEL. Per-run approval.
public struct MacUiTapCapability: Capability {
    public let name = "mac.ui.tap"
    public let purpose = "Click an element in the frontmost app by its visible label. Input: the label, e.g. \"Send\"."
    public let tier = CapabilityTier.appAction
    public let blastRadius = BlastRadius.write(resource: "the frontmost app")
    private let ui: any MacUi
    public init(ui: any MacUi) { self.ui = ui }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard ui.available else { return ActionPreview(summary: uiNoMac, mutates: false) }
        let els: [MacUiElement]
        do { els = try await ui.observe() } catch { return ActionPreview(summary: describeUiError(error), mutates: false) }
        switch resolve(els, input) {
        case .message(let m): return ActionPreview(summary: m, mutates: false)
        case .element(let e): return ActionPreview(summary: "Click \"\(e.label)\" (\(e.role)) in the frontmost app.", mutates: true)
        }
    }

    public func run(_ input: String) async throws -> String {
        guard ui.available else { return uiNoMac }
        let els: [MacUiElement]
        do { els = try await ui.observe() } catch { return describeUiError(error) }
        let resolved: MacUiElement
        switch resolve(els, input) {
        case .message(let m): return m
        case .element(let e): resolved = e
        }
        // Defense in depth: re-check the RESOLVED element's real label+role. The runner already
        // scanned the input string; this catches an element that reads innocuous but is dangerous.
        if let hit = SafetyBlocklist.matches(in: "\(resolved.label) \(resolved.role)").first {
            return "Refused: that element looks like a blocked action ('\(hit)')."
        }
        do { try await ui.click(resolved.label) } catch { return describeUiError(error) }
        return "Clicked \"\(resolved.label)\"."
    }
}

/// T3: type into the focused field. Per-run approval.
public struct MacUiTypeCapability: Capability {
    public let name = "mac.ui.type"
    public let purpose = "Type text into the focused field of the frontmost macOS app. Input: the text to type."
    public let tier = CapabilityTier.appAction
    public let blastRadius = BlastRadius.write(resource: "the frontmost app")
    private let ui: any MacUi
    public init(ui: any MacUi) { self.ui = ui }

    public func plan(_ input: String) async throws -> ActionPreview {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return ActionPreview(summary: "Input is the text to type.", mutates: false) }
        let shown = text.count > 80 ? String(text.prefix(80)) + "…" : text
        return ActionPreview(summary: "Type \"\(shown)\" into the focused field.", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard ui.available else { return uiNoMac }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Nothing to type." }
        do { try await ui.typeText(text) } catch { return describeUiError(error) }
        let shown = text.count > 80 ? String(text.prefix(80)) + "…" : text
        return "Typed \"\(shown)\"."
    }
}

/// T3: click a menu-bar item, e.g. "File > Save As" — the menu bar reaches actions no window button
/// exposes (Export, Select All, Preferences…). Per-run approval; the resolved item is blocklist-
/// re-checked. Supports nested submenus of any depth: "Format > Font > Bold".
public struct MacUiMenuCapability: Capability {
    public let name = "mac.ui.menu"
    public let purpose = "Click a menu-bar item in the frontmost app. Input: \"<Menu> > <Item>\" (nesting OK, e.g. \"Format > Font > Bold\")."
    public let tier = CapabilityTier.appAction
    public let blastRadius = BlastRadius.write(resource: "the frontmost app")
    private let ui: any MacUi
    public init(ui: any MacUi) { self.ui = ui }

    /// Split a "A > B > C" path; require at least a menu and an item, every segment non-empty.
    private func parse(_ input: String) -> [String]? {
        let parts = input.split(separator: ">", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } ? parts : nil
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard ui.available else { return ActionPreview(summary: uiNoMac, mutates: false) }
        guard let p = parse(input) else {
            return ActionPreview(summary: "Input must be \"<Menu> > <Item>\", e.g. \"File > Save As\".", mutates: false)
        }
        return ActionPreview(summary: "Click menu \"\(p.joined(separator: " > "))\" in the frontmost app.", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard ui.available else { return uiNoMac }
        guard let p = parse(input) else { return "Input must be \"<Menu> > <Item>\", e.g. \"File > Save As\"." }
        // Defense in depth: re-check the WHOLE resolved menu path (the runner scanned the raw input too).
        if let hit = SafetyBlocklist.matches(in: p.joined(separator: " ")).first {
            return "Refused: that menu item looks like a blocked action ('\(hit)')."
        }
        do { try await ui.clickMenu(p) } catch { return describeUiError(error) }
        return "Clicked menu \"\(p.joined(separator: " > "))\"."
    }
}

/// T3: press a navigation key (return, tab, escape, arrows, page up/down). Per-run approval — a key
/// can submit or dismiss.
public struct MacUiKeyCapability: Capability {
    public let name = "mac.ui.key"
    public let purpose = "Press a key in the frontmost macOS app. Input: return, tab, escape, up, down, left, right, pageup, or pagedown."
    public let tier = CapabilityTier.appAction
    public let blastRadius = BlastRadius.write(resource: "the frontmost app")
    private static let allowed: Set<String> = ["return", "tab", "escape", "up", "down", "left", "right", "pageup", "pagedown"]
    private let ui: any MacUi
    public init(ui: any MacUi) { self.ui = ui }

    public func plan(_ input: String) async throws -> ActionPreview {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.allowed.contains(key) else {
            return ActionPreview(summary: "Input must be a navigation key (return, tab, escape, up, down, left, right, pageup, pagedown).", mutates: false)
        }
        return ActionPreview(summary: "Press the \"\(key)\" key.", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard ui.available else { return uiNoMac }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.allowed.contains(key) else {
            return "Input must be a navigation key: return, tab, escape, up, down, left, right, pageup, pagedown."
        }
        do { try await ui.pressKey(key) } catch { return describeUiError(error) }
        return "Pressed \"\(key)\"."
    }
}

// ─── shared helpers ─────────────────────────────────────────────────────────────────────────

private enum Resolved {
    case element(MacUiElement)
    case message(String)
}

/// Resolve a visible label to exactly one element, or an explanation (mirrors the TS `resolve`).
private func resolve(_ els: [MacUiElement], _ input: String) -> Resolved {
    let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if query.isEmpty { return .message("Input is the visible label of the element to click.") }
    let exact = els.filter { $0.label.lowercased() == query }
    let partial = els.filter { $0.label.lowercased().contains(query) }
    let matches = !exact.isEmpty ? exact : partial
    if matches.isEmpty { return .message("No element labeled \"\(input)\". Use mac.ui.observe to see what's on screen.") }
    if matches.count > 1 { return .message("\"\(input)\" matches \(matches.count) elements — be more specific.") }
    return .element(matches[0])
}

private func describeUiError(_ error: Error) -> String {
    switch error {
    case MacAutomationError.notMac:
        return uiNoMac
    case MacAutomationError.timeout:
        return "Timed out driving the app — it may be busy or waiting on a permission prompt. Try again."
    case MacAutomationError.script(let msg):
        if msg.range(of: "not allowed|Not authori|-1743|assistive|accessibility",
                     options: [.regularExpression, .caseInsensitive]) != nil {
            return uiNoPermission
        }
        return "Couldn't drive the app: \(msg)"
    default:
        return "Couldn't drive the app: \(String(describing: error))"
    }
}

/// The macOS GUI-driving toolkit — observe (T1) + tap/type/menu/key (T3), all on one accessibility
/// seam. Same membership and order as the TS twin's `macUiCapabilities(ui)`.
public func macUiCapabilities(ui: any MacUi) -> [any Capability] {
    [
        MacUiObserveCapability(ui: ui),
        MacUiTapCapability(ui: ui),
        MacUiTypeCapability(ui: ui),
        MacUiKeyCapability(ui: ui),
        MacUiMenuCapability(ui: ui),
    ]
}
