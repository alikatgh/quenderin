import Foundation

/// The native macOS capability library — "say a thing, Quenderin does it on your Mac", governed.
/// Each capability wraps a BOUNDED AppleScript template over the `MacAutomation` seam with typed,
/// escaped input — never "run arbitrary script". Ported 1:1 from the desktop lab's proven
/// TypeScript library (`src/services/capability/macCapabilities.ts`), which remains the reference:
/// same names, same tiers, same templates, same messages — so behavior notes and fixes carry
/// across. Registered in `AgentToolkit` on macOS only; the existing spine (gate → consent →
/// preview → per-run approval → ledger) governs them with zero new plumbing.
///
/// Undo, honestly: the Swift spine's `UndoJournal` is file-move-specific today, so these previews
/// carry the manual undo path in words ("delete it in Reminders to undo") — the same hint the TS
/// twins show. A generic action journal is named follow-up work, not silently skipped.

private let notMacMessage = "This runs on macOS only."

/// Human-readable failure for a mac automation error — including the one every first-time user
/// hits: the macOS Automation permission prompt.
func describeMacError(_ error: Error, action: String) -> String {
    if let macError = error as? MacAutomationError {
        switch macError {
        case .notMac: return notMacMessage
        case .timeout: return "Timed out trying to \(action)."
        case .script(let message):
            if message.range(of: "not allowed|Not authori|-1743|assistive access",
                             options: [.regularExpression, .caseInsensitive]) != nil {
                return "macOS blocked the action — grant Quenderin permission to control the app in System Settings › Privacy & Security › Automation, then try again."
            }
            return "Couldn't \(action): \(message)"
        }
    }
    return "Couldn't \(action): \(String(describing: error))"
}

// MARK: - Perception (T1 — consent, no approval)

/// T1: what app is frontmost right now — cheap perception, "what am I looking at?".
public struct FrontAppCapability: Capability {
    public let name = "mac.frontApp"
    public let purpose = "Name the frontmost (active) macOS app. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "the active app name")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read which app is frontmost (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let script = "tell application \"System Events\" to return name of first application process whose frontmost is true"
        do {
            let name = try await mac.runAppleScript(script)
            return name.isEmpty ? "Could not tell which app is frontmost." : "The frontmost app is \(name)."
        } catch {
            return describeMacError(error, action: "read the active app")
        }
    }
}

/// T1: read the clipboard — huge for agent context ("use what I just copied"). Read-only.
public struct ClipboardReadCapability: Capability {
    public let name = "mac.clipboard.read"
    public let purpose = "Read the current text on the macOS clipboard. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "the clipboard")
    private let mac: any MacAutomation
    private let maxChars: Int

    public init(mac: any MacAutomation, maxChars: Int = 4000) {
        self.mac = mac
        self.maxChars = maxChars
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read the text currently on your clipboard (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        do {
            let text = try await mac.runAppleScript("return (the clipboard as text)")
            if text.isEmpty { return "The clipboard is empty (or holds no text)." }
            return text.count > maxChars ? String(text.prefix(maxChars)) + "\n[…clipboard truncated]" : text
        } catch {
            return describeMacError(error, action: "read the clipboard")
        }
    }
}

/// T1: read today's calendar events. Read-only — no approval.
public struct CalendarTodayCapability: Capability {
    public let name = "mac.calendar.today"
    public let purpose = "List the titles and times of today's macOS Calendar events. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "macOS Calendar (today)")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would read today's Calendar events (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let script = [
            "set out to \"\"",
            "set today to current date",
            "set startOfDay to today - (time of today)",
            "set endOfDay to startOfDay + 86399",
            "tell application \"Calendar\"",
            "  repeat with c in calendars",
            "    repeat with e in (every event of c whose start date ≥ startOfDay and start date ≤ endOfDay)",
            "      set out to out & (summary of e) & \" @ \" & (time string of (start date of e)) & linefeed",
            "    end repeat",
            "  end repeat",
            "end tell",
            "return out",
        ].joined(separator: "\n")
        do {
            let out = try await mac.runAppleScript(script)
            return out.isEmpty ? "No events on your calendar today." : out
        } catch {
            return describeMacError(error, action: "read your calendar")
        }
    }
}

/// T1: list the user's Apple Shortcuts by name — perception for `mac.shortcuts.run` (the model
/// names what it can see, exactly like fs.list → fs.move). Read-only.
public struct ShortcutListCapability: Capability {
    public let name = "mac.shortcuts.list"
    public let purpose = "List the names of your Apple Shortcuts. No input."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "your Shortcuts library (names)")
    private let mac: any MacAutomation
    private let maxNames: Int

    public init(mac: any MacAutomation, maxNames: Int = 200) {
        self.mac = mac
        self.maxNames = maxNames
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        ActionPreview(summary: "Would list the names of your Apple Shortcuts (read-only).", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let script = [
            "set out to \"\"",
            "tell application \"Shortcuts Events\"",
            "  repeat with s in shortcuts",
            "    set out to out & (name of s) & linefeed",
            "  end repeat",
            "end tell",
            "return out",
        ].joined(separator: "\n")
        do {
            let names = try await mac.runAppleScript(script)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if names.isEmpty { return "You have no Apple Shortcuts yet." }
            let shown = names.prefix(maxNames)
            let tail = names.count > maxNames ? "\n[…\(names.count - maxNames) more]" : ""
            return shown.joined(separator: "\n") + tail
        } catch {
            return describeMacError(error, action: "list your Shortcuts")
        }
    }
}

/// T1: reveal a file or folder in Finder — shows and selects it, brings Finder to front. A "show
/// me" action with no data change (the natural finish to a file task). Input: a path (a leading ~
/// is expanded). Read-only tier: it navigates, it doesn't mutate.
public struct FinderRevealCapability: Capability {
    public let name = "mac.finder.reveal"
    public let purpose = "Reveal a file or folder in Finder. Input: a path, e.g. \"~/Downloads/report.pdf\"."
    public let tier = CapabilityTier.readOnly
    public let blastRadius = BlastRadius.read(resource: "Finder (shows a file)")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    /// A plausible filesystem path, tilde-expanded. Rejects empties and control characters.
    func clean(_ input: String) -> String? {
        let expanded = (input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty,
              expanded.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F }) else { return nil }
        return expanded
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        if let p = clean(input) {
            return ActionPreview(summary: "Would show \"\(p)\" in Finder (read-only).", mutates: false)
        }
        return ActionPreview(summary: "Input is a file or folder path.", mutates: false)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        guard let p = clean(input) else { return "Input is a file or folder path, e.g. \"~/Downloads\"." }
        let script = [
            "tell application \"Finder\"",
            "  reveal (POSIX file \"\(escapeAppleScriptString(p))\")",
            "  activate",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            return "Showed \"\(p)\" in Finder."
        } catch {
            if case MacAutomationError.script(let message) = error,
               message.range(of: "can.t|isn.t|not found|-1728|-10006",
                             options: [.regularExpression, .caseInsensitive]) != nil {
                return "Couldn't find \"\(p)\" to show."
            }
            return describeMacError(error, action: "show \"\(p)\" in Finder")
        }
    }
}

// MARK: - Action (T2 — per-run approval)

/// T2: open (launch/activate) an app by name. A side effect, so approved — reversible (just quit).
public struct OpenAppCapability: Capability {
    public let name = "mac.app.open"
    public let purpose = "Open (launch and bring to front) a macOS app. Input: the app name, e.g. \"Safari\"."
    public let tier = CapabilityTier.reversibleWrite
    public let blastRadius = BlastRadius.write(resource: "the desktop (launches an app)")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    public func plan(_ input: String) async throws -> ActionPreview {
        let app = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return ActionPreview(summary: "Input is the app name to open.", mutates: false) }
        return ActionPreview(summary: "Open \"\(app)\" and bring it to the front (quit it to undo).", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let app = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return "Nothing to open — the app name is empty." }
        let script = "tell application \"\(escapeAppleScriptString(app))\" to activate"
        do {
            _ = try await mac.runAppleScript(script)
            return "Opened \"\(app)\"."
        } catch {
            if case MacAutomationError.script(let message) = error,
               message.range(of: "Can’t get application|isn't running|-1728|-10814|not found",
                             options: [.regularExpression, .caseInsensitive]) != nil {
                return "Couldn't find an app named \"\(app)\"."
            }
            return describeMacError(error, action: "open \"\(app)\"")
        }
    }
}

/// T2: open a URL in the default browser. Common, low-stakes, reversible (close the tab).
public struct OpenURLCapability: Capability {
    public let name = "mac.safari.openURL"
    public let purpose = "Open a web URL in the browser. Input: an http(s) URL."
    public let tier = CapabilityTier.reversibleWrite
    public let blastRadius = BlastRadius.write(resource: "the browser (opens a page)")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    /// Only http(s), no whitespace — a URL is not a place for AppleScript/shell surprises.
    private func isValid(_ url: String) -> Bool {
        url.range(of: #"^https?://[^\s"]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        let url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(url) else { return ActionPreview(summary: "Input must be an http(s) URL.", mutates: false) }
        return ActionPreview(summary: "Open \(url) in the browser.", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(url) else { return "Input must be an http(s) URL (no spaces)." }
        do {
            _ = try await mac.runAppleScript("open location \"\(escapeAppleScriptString(url))\"")
            return "Opened \(url)."
        } catch {
            return describeMacError(error, action: "open the URL")
        }
    }
}

/// T2: add a Reminder with a title. A create — undoable (the session deletes what it added).
public struct ReminderAddCapability: UndoableCapability {
    public let name = "mac.reminders.add"
    public let purpose = "Add a reminder to macOS Reminders. Input: the reminder text."
    public let tier = CapabilityTier.reversibleWrite
    public let blastRadius = BlastRadius.write(resource: "macOS Reminders")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    public func plan(_ input: String) async throws -> ActionPreview {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ActionPreview(summary: "Input is the reminder text.", mutates: false) }
        let shown = title.count > 80 ? String(title.prefix(80)) + "…" : title
        return ActionPreview(summary: "Add a reminder: \"\(shown)\" (delete it in Reminders to undo).", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Nothing to add — the reminder text is empty." }
        let script = [
            "tell application \"Reminders\"",
            "  make new reminder with properties {name:\"\(escapeAppleScriptString(title))\"}",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            let shown = title.count > 80 ? String(title.prefix(80)) + "…" : title
            return "Added a reminder: \"\(shown)\"."
        } catch {
            return describeMacError(error, action: "add the reminder")
        }
    }

    /// Undo = delete the reminder(s) with that exact name. Right after a session that just created
    /// it, this reverses that create. (Limitation, same as the TS twin: deletes any reminder of
    /// the same name — the honest v1 tradeoff for a dependency-free undo.)
    public func undo(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = [
            "tell application \"Reminders\"",
            "  delete (every reminder whose name is \"\(escapeAppleScriptString(title))\")",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            return "Removed the reminder \"\(title)\"."
        } catch {
            return describeMacError(error, action: "remove the reminder")
        }
    }
}

/// T2: create a Note with a title/body. A create — undoable (the session deletes what it made).
public struct NoteCreateCapability: UndoableCapability {
    public let name = "mac.notes.create"
    public let purpose = "Create a note in macOS Notes. Input: the note text (first line becomes the title)."
    public let tier = CapabilityTier.reversibleWrite
    public let blastRadius = BlastRadius.write(resource: "macOS Notes")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    public func plan(_ input: String) async throws -> ActionPreview {
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return ActionPreview(summary: "Input is the note text.", mutates: false) }
        let title = body.split(separator: "\n", maxSplits: 1)[0]
        let shown = title.count > 60 ? String(title.prefix(60)) + "…" : String(title)
        return ActionPreview(summary: "Create a note \"\(shown)\" (delete it in Notes to undo).", mutates: true)
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "Nothing to write — the note text is empty." }
        let escaped = escapeAppleScriptString(body)
        let primary = [
            "tell application \"Notes\"",
            "  make new note at folder \"Notes\" of account \"iCloud\" with properties {body:\"\(escaped)\"}",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        // The iCloud account/folder isn't guaranteed; fall back to the default container.
        let fallback = [
            "tell application \"Notes\"",
            "  make new note with properties {body:\"\(escaped)\"}",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        let title = body.split(separator: "\n", maxSplits: 1)[0]
        let shown = title.count > 60 ? String(title.prefix(60)) + "…" : String(title)
        do {
            _ = try await mac.runAppleScript(primary)
            return "Created a note \"\(shown)\"."
        } catch {
            do {
                _ = try await mac.runAppleScript(fallback)
                return "Created a note \"\(shown)\"."
            } catch {
                return describeMacError(error, action: "create the note")
            }
        }
    }

    /// Undo = delete the note(s) whose name matches the created title (first line of the input).
    public func undo(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        let title = String(input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1)[0])
        let script = [
            "tell application \"Notes\"",
            "  delete (every note whose name is \"\(escapeAppleScriptString(title))\")",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            let shown = title.count > 60 ? String(title.prefix(60)) + "…" : title
            return "Removed the note \"\(shown)\"."
        } catch {
            return describeMacError(error, action: "remove the note")
        }
    }
}

/// T2: add an event to Calendar — makes the calendar two-way (read via mac.calendar.today, write
/// here). ROBUST date handling is the trick: the target is computed as an OFFSET in seconds from
/// now HERE (reliable), and AppleScript does `(current date) + offset` — no locale-fragile
/// date-string parsing or month-component coercion, which is where naive AppleScript calendar
/// code breaks (the technique the TS twin proved). Input:
/// "<title> | <YYYY-MM-DD HH:MM> | <duration minutes>" (duration optional, default 60).
public struct CalendarAddCapability: UndoableCapability {
    public let name = "mac.calendar.add"
    public let purpose = "Add an event to macOS Calendar. Input: \"<title> | <YYYY-MM-DD HH:MM> | <minutes>\" (minutes optional, default 60)."
    public let tier = CapabilityTier.reversibleWrite
    public let blastRadius = BlastRadius.write(resource: "macOS Calendar")
    private let mac: any MacAutomation
    private let now: @Sendable () -> Date

    public init(mac: any MacAutomation, now: @escaping @Sendable () -> Date = { Date() }) {
        self.mac = mac
        self.now = now
    }

    struct Parsed {
        let title: String
        let target: Date
        let durationMinutes: Int
    }

    func parse(_ input: String) -> Parsed? {
        let parts = input.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$"#
        guard let match = parts[1].range(of: pattern, options: .regularExpression) else { return nil }
        let digits = parts[1][match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count == 5 else { return nil }
        let (y, mo, d, h, mi) = (digits[0], digits[1], digits[2], digits[3], digits[4])
        guard (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59 else { return nil }
        // Reject rolled-over dates (Feb 30 must fail, not become Mar 2) — components must round-trip.
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi
        let cal = Calendar(identifier: .gregorian)
        guard let target = cal.date(from: comps) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: target)
        guard back.year == y, back.month == mo, back.day == d else { return nil }
        var durationMinutes = 60
        if parts.count >= 3, !parts[2].isEmpty {
            guard let n = Int(parts[2]), n > 0 else { return nil }
            durationMinutes = min(n, 24 * 60)
        }
        return Parsed(title: parts[0], target: target, durationMinutes: durationMinutes)
    }

    /// Seconds from now to `date` — so AppleScript builds the date as `(current date) + offset`.
    private func offsetSeconds(to date: Date) -> Int {
        Int((date.timeIntervalSince1970 - now().timeIntervalSince1970).rounded())
    }

    private func human(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard let p = parse(input) else {
            return ActionPreview(summary: "Input must be \"<title> | <YYYY-MM-DD HH:MM> | <minutes>\".", mutates: false)
        }
        return ActionPreview(
            summary: "Add \"\(p.title)\" to Calendar on \(human(p.target)) for \(p.durationMinutes) min (delete it in Calendar to undo).",
            mutates: true
        )
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        guard let p = parse(input) else { return "Input must be \"<title> | <YYYY-MM-DD HH:MM> | <minutes>\"." }
        let script = [
            "tell application \"Calendar\"",
            "  tell (first calendar whose writable is true)",
            "    set d to (current date) + (\(offsetSeconds(to: p.target)))",
            "    make new event with properties {summary:\"\(escapeAppleScriptString(p.title))\", start date:d, end date:d + (\(p.durationMinutes) * minutes)}",
            "  end tell",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            return "Added \"\(p.title)\" to your calendar on \(human(p.target))."
        } catch {
            return describeMacError(error, action: "add the calendar event")
        }
    }

    /// Undo = delete events with that title on the target DAY (a bounded window, so it can't nuke
    /// a same-named event on another day; the create slop is well inside the day).
    public func undo(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        guard let p = parse(input) else { return "Nothing to undo." }
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: p.target)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600 - 1)
        let script = [
            "tell application \"Calendar\"",
            "  tell (first calendar whose writable is true)",
            "    set ds to (current date) + (\(offsetSeconds(to: dayStart)))",
            "    set de to (current date) + (\(offsetSeconds(to: dayEnd)))",
            "    delete (every event whose summary is \"\(escapeAppleScriptString(p.title))\" and start date ≥ ds and start date ≤ de)",
            "  end tell",
            "end tell",
            "return \"ok\"",
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            return "Removed \"\(p.title)\" from your calendar."
        } catch {
            return describeMacError(error, action: "remove the calendar event")
        }
    }
}

/// T2: compose a Mail DRAFT — it writes the email and shows it, but NEVER sends (send is a human
/// decision; the template deliberately has no `send`). Input:
/// "to: a@b.com | subject: … | body: …" (subject/body optional).
public struct MailDraftCapability: Capability {
    public let name = "mac.mail.draft"
    public let purpose = "Draft an email in Mail (does NOT send). Input: \"to: <address> | subject: <s> | body: <b>\"."
    public let tier = CapabilityTier.reversibleWrite
    public let blastRadius = BlastRadius.write(resource: "Mail (a draft — never sent)")
    private let mac: any MacAutomation

    public init(mac: any MacAutomation) { self.mac = mac }

    struct Fields {
        let to: String
        let subject: String
        let body: String
    }

    func parse(_ input: String) -> Fields? {
        var fields: [String: String] = [:]
        for part in input.split(separator: "|") {
            guard let idx = part.firstIndex(of: ":") else { continue }
            let key = part[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        let to = fields["to"] ?? ""
        // One plausible address — same shape check as the TS twin.
        guard to.range(of: #"^[^\s@"]+@[^\s@"]+\.[^\s@"]+$"#, options: .regularExpression) != nil else { return nil }
        return Fields(to: to, subject: fields["subject"] ?? "", body: fields["body"] ?? "")
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard let f = parse(input) else {
            return ActionPreview(summary: "Input must include a valid \"to: <address>\".", mutates: false)
        }
        let subj = f.subject.isEmpty ? "" : " \"\(f.subject)\""
        return ActionPreview(
            summary: "Draft an email to \(f.to)\(subj) — it will NOT be sent; you review and send it yourself.",
            mutates: true
        )
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        guard let f = parse(input) else { return "Input must include a valid \"to: <address>\"." }
        let script = [
            "tell application \"Mail\"",
            "  set msg to make new outgoing message with properties {subject:\"\(escapeAppleScriptString(f.subject))\", content:\"\(escapeAppleScriptString(f.body))\", visible:true}",
            "  tell msg to make new to recipient with properties {address:\"\(escapeAppleScriptString(f.to))\"}",
            "end tell",
            "return \"ok\"",
            // Deliberately NO `send msg` — drafting is T2, sending is a human decision.
        ].joined(separator: "\n")
        do {
            _ = try await mac.runAppleScript(script)
            return "Drafted an email to \(f.to) (open in Mail, not sent — review and send it yourself)."
        } catch {
            return describeMacError(error, action: "draft the email")
        }
    }
}

// MARK: - The Shortcuts library (T3 — per-run approval)

/// T3: run one of the user's EXISTING Apple Shortcuts by name — the lodestar ("Apple bought
/// Workflow, not an AI that clicks things"). It invokes a shortcut the USER already authored, BY
/// NAME, behind per-run approval — never a "run arbitrary script" hole: it can't create or edit a
/// shortcut, only call one that exists. The shortcut's own effects are arbitrary, so this is T3
/// with a truthful preview and no undo. Input: the shortcut name, optionally "<name> | <text>".
public struct ShortcutRunCapability: Capability {
    public let name = "mac.shortcuts.run"
    public let purpose = "Run one of your Apple Shortcuts by name. Input: the shortcut name, or \"<name> | <input text>\"."
    public let tier = CapabilityTier.appAction
    public let blastRadius = BlastRadius.write(resource: "your Shortcuts (runs a shortcut you built)")
    private let mac: any MacAutomation
    private let maxChars: Int

    public init(mac: any MacAutomation, maxChars: Int = 4000) {
        self.mac = mac
        self.maxChars = maxChars
    }

    func parse(_ input: String) -> (name: String, text: String?)? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let idx = raw.firstIndex(of: "|") else { return (raw, nil) }
        let name = raw[..<idx].trimmingCharacters(in: .whitespaces)
        let text = raw[raw.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, text.isEmpty ? nil : text)
    }

    public func plan(_ input: String) async throws -> ActionPreview {
        guard let f = parse(input) else {
            return ActionPreview(summary: "Input is the shortcut name (use `mac.shortcuts.list` to see them).", mutates: false)
        }
        let withText = f.text.map { " with input \"\($0.count > 40 ? String($0.prefix(40)) + "…" : $0)\"" } ?? ""
        return ActionPreview(
            summary: "Run your shortcut \"\(f.name)\"\(withText) — it does whatever you built it to do.",
            mutates: true
        )
    }

    public func run(_ input: String) async throws -> String {
        guard mac.available else { return notMacMessage }
        guard let f = parse(input) else { return "Input is the shortcut name — see `mac.shortcuts.list` for what you have." }
        let invoke: String
        if let text = f.text {
            invoke = "run shortcut \"\(escapeAppleScriptString(f.name))\" with input \"\(escapeAppleScriptString(text))\""
        } else {
            invoke = "run shortcut \"\(escapeAppleScriptString(f.name))\""
        }
        let script = [
            "tell application \"Shortcuts Events\"",
            "  set outVal to \(invoke)",
            "end tell",
            "if outVal is missing value then return \"\"",
            "try",
            "  return (outVal as text)",
            "on error",
            "  return \"\"",
            "end try",
        ].joined(separator: "\n")
        do {
            let out = try await mac.runAppleScript(script)
            if out.isEmpty { return "Ran your shortcut \"\(f.name)\"." }
            let shown = out.count > maxChars ? String(out.prefix(maxChars)) + "\n[…output truncated]" : out
            return "Ran your shortcut \"\(f.name)\". It returned:\n\(shown)"
        } catch {
            if case MacAutomationError.script(let message) = error,
               message.range(of: "Can’t get shortcut|not found|missing value|-1728",
                             options: [.regularExpression, .caseInsensitive]) != nil {
                return "No shortcut named \"\(f.name)\". Use `mac.shortcuts.list` to see yours."
            }
            return describeMacError(error, action: "run the shortcut \"\(f.name)\"")
        }
    }
}

/// The macOS capability set — grows as capabilities are added; the spine stays fixed. Same
/// membership and order as the TS twin's `macCapabilities(mac)`.
public func macCapabilities(mac: any MacAutomation) -> [any Capability] {
    [
        // Perception (T1 — no approval)
        FrontAppCapability(mac: mac),
        ClipboardReadCapability(mac: mac),
        CalendarTodayCapability(mac: mac),
        ShortcutListCapability(mac: mac),
        FinderRevealCapability(mac: mac),
        // Action (T2 — per-run approval)
        OpenAppCapability(mac: mac),
        OpenURLCapability(mac: mac),
        NoteCreateCapability(mac: mac),
        ReminderAddCapability(mac: mac),
        CalendarAddCapability(mac: mac),
        MailDraftCapability(mac: mac),   // drafts, never sends
        // The Shortcuts library (T3 — per-run approval): the user's whole automation surface
        ShortcutRunCapability(mac: mac),
    ]
}
