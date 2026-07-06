import { Capability, CapabilityTier, BlastRadius, ActionPreview } from './capability.js';
import { MacAutomation, escapeAppleScriptString } from './macAutomation.js';

/**
 * The first native-macOS capabilities (the sharpened mission: "say a thing, Quenderin does it on
 * your Mac"). Each wraps a BOUNDED AppleScript template over the `MacAutomation` seam with a typed,
 * escaped input — never "run arbitrary script". This is how "anything possible in macOS" is
 * reached: a growing library of governed actions (the Shortcuts model), each with a declared blast
 * radius, a truthful preview, and — for writes — per-run approval. Add capabilities to grow reach;
 * the safety spine never bends.
 */

const NOT_MAC = 'This runs on macOS only.';

/** T1: read today's calendar events. Read-only — no approval. */
export class CalendarTodayCapability implements Capability {
    readonly name = 'mac.calendar.today';
    readonly purpose = 'List the titles and times of today\'s macOS Calendar events. No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'macOS Calendar (today)' };

    constructor(private readonly mac: MacAutomation) { }

    async plan(): Promise<ActionPreview> {
        return { summary: 'Would read today\'s Calendar events (read-only).', mutates: false };
    }

    async run(): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        // Reads only: gathers today's event summaries + start times from all calendars.
        const script = [
            'set out to ""',
            'set today to current date',
            'set startOfDay to today - (time of today)',
            'set endOfDay to startOfDay + 86399',
            'tell application "Calendar"',
            '  repeat with c in calendars',
            '    repeat with e in (every event of c whose start date ≥ startOfDay and start date ≤ endOfDay)',
            '      set out to out & (summary of e) & " @ " & (time string of (start date of e)) & linefeed',
            '    end repeat',
            '  end repeat',
            'end tell',
            'return out',
        ].join('\n');
        try {
            const out = (await this.mac.runAppleScript(script)).trim();
            return out.length > 0 ? out : 'No events on your calendar today.';
        } catch (e) {
            return describeMacError(e, 'read your calendar');
        }
    }
}

/**
 * T2: add an event to Calendar — makes the calendar two-way (read via mac.calendar.today, write
 * here). ROBUST date handling is the trick: we compute the target as an OFFSET in seconds from now
 * in JS (reliable), and let AppleScript do `(current date) + offset` — NO locale-fragile date-string
 * parsing or month-component coercion, which is where naive AppleScript calendar code breaks.
 * Undoable (deletes the event we made, scoped to its title on its day). Input:
 * "<title> | <YYYY-MM-DD HH:MM> | <duration minutes>" (duration optional, default 60).
 */
export class CalendarAddCapability implements Capability {
    readonly name = 'mac.calendar.add';
    readonly purpose = 'Add an event to macOS Calendar. Input: "<title> | <YYYY-MM-DD HH:MM> | <minutes>" (minutes optional, default 60).';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'macOS Calendar' };

    constructor(private readonly mac: MacAutomation, private readonly now: () => number = () => Date.now()) { }

    private parse(input: string): { title: string; target: Date; durMin: number } | null {
        const parts = input.split('|').map(s => s.trim());
        if (parts.length < 2) return null;
        const title = parts[0];
        const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/.exec(parts[1]);
        if (!title || !m) return null;
        const y = +m[1], mo = +m[2], d = +m[3], h = +m[4], mi = +m[5];
        if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
        const target = new Date(y, mo - 1, d, h, mi, 0, 0);
        // Reject rolled-over dates (JS turns Feb 30 into Mar 2) — the components must round-trip.
        if (isNaN(target.getTime()) || target.getFullYear() !== y || target.getMonth() !== mo - 1 || target.getDate() !== d) return null;
        let durMin = 60;
        if (parts[2]) { const n = parseInt(parts[2], 10); if (isNaN(n) || n <= 0) return null; durMin = Math.min(n, 24 * 60); }
        return { title, target, durMin };
    }

    /** Seconds from now to `to` — so AppleScript builds the date as `(current date) + offset`. */
    private offsetSec(to: Date): number { return Math.round((to.getTime() - this.now()) / 1000); }

    private human(d: Date): string {
        const p = (n: number) => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
    }

    async plan(input: string): Promise<ActionPreview> {
        const p = this.parse(input);
        if (!p) return { summary: 'Input must be "<title> | <YYYY-MM-DD HH:MM> | <minutes>".', mutates: false };
        return { summary: `Add "${p.title}" to Calendar on ${this.human(p.target)} for ${p.durMin} min (delete it in Calendar to undo).`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const p = this.parse(input);
        if (!p) return 'Input must be "<title> | <YYYY-MM-DD HH:MM> | <minutes>".';
        const script = [
            'tell application "Calendar"',
            '  tell (first calendar whose writable is true)',
            `    set d to (current date) + (${this.offsetSec(p.target)})`,
            `    make new event with properties {summary:"${escapeAppleScriptString(p.title)}", start date:d, end date:d + (${p.durMin} * minutes)}`,
            '  end tell',
            'end tell',
            'return "ok"',
        ].join('\n');
        try {
            await this.mac.runAppleScript(script);
            return `Added "${p.title}" to your calendar on ${this.human(p.target)}.`;
        } catch (e) {
            return describeMacError(e, 'add the calendar event');
        }
    }

    /** Undo = delete events with that title on the target DAY (a bounded window, so it can't nuke a
     *  same-named event on another day; the ±1s create slop is well inside the day). */
    async undo(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const p = this.parse(input);
        if (!p) return 'Nothing to undo.';
        const dayStart = new Date(p.target.getFullYear(), p.target.getMonth(), p.target.getDate(), 0, 0, 0);
        const dayEnd = new Date(p.target.getFullYear(), p.target.getMonth(), p.target.getDate(), 23, 59, 59);
        const script = [
            'tell application "Calendar"',
            '  tell (first calendar whose writable is true)',
            `    set ds to (current date) + (${this.offsetSec(dayStart)})`,
            `    set de to (current date) + (${this.offsetSec(dayEnd)})`,
            `    delete (every event whose summary is "${escapeAppleScriptString(p.title)}" and start date ≥ ds and start date ≤ de)`,
            '  end tell',
            'end tell',
            'return "ok"',
        ].join('\n');
        try {
            await this.mac.runAppleScript(script);
            return `Removed "${p.title}" from your calendar.`;
        } catch (e) {
            return describeMacError(e, 'remove the calendar event');
        }
    }
}

/** T2: add a Reminder with a title. A create — low-stakes and reversible (the user deletes it). */
export class ReminderAddCapability implements Capability {
    readonly name = 'mac.reminders.add';
    readonly purpose = 'Add a reminder to macOS Reminders. Input: the reminder text.';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'macOS Reminders' };

    constructor(private readonly mac: MacAutomation) { }

    async plan(input: string): Promise<ActionPreview> {
        const title = input.trim();
        if (!title) return { summary: 'Input is the reminder text.', mutates: false };
        const shown = title.length > 80 ? title.slice(0, 80) + '…' : title;
        return { summary: `Add a reminder: "${shown}" (delete it in Reminders to undo).`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const title = input.trim();
        if (!title) return 'Nothing to add — the reminder text is empty.';
        const escaped = escapeAppleScriptString(title);
        const script = [
            'tell application "Reminders"',
            `  make new reminder with properties {name:"${escaped}"}`,
            'end tell',
            'return "ok"',
        ].join('\n');
        try {
            await this.mac.runAppleScript(script);
            const shown = title.length > 80 ? title.slice(0, 80) + '…' : title;
            return `Added a reminder: "${shown}".`;
        } catch (e) {
            return describeMacError(e, 'add the reminder');
        }
    }

    /** Undo = delete the reminder(s) with that exact name. Right after a session that just created
     *  it, this reverses that create. (Limitation: deletes any reminder of the same name — the
     *  honest v1 tradeoff for a dependency-free undo; a future id-tracked version is cleaner.) */
    async undo(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const escaped = escapeAppleScriptString(input.trim());
        const script = [
            'tell application "Reminders"',
            `  delete (every reminder whose name is "${escaped}")`,
            'end tell',
            'return "ok"',
        ].join('\n');
        try {
            await this.mac.runAppleScript(script);
            return `Removed the reminder "${input.trim()}".`;
        } catch (e) {
            return describeMacError(e, 'remove the reminder');
        }
    }
}

/** T1: what app is frontmost right now — cheap perception, "what am I looking at?". */
export class FrontAppCapability implements Capability {
    readonly name = 'mac.frontApp';
    readonly purpose = 'Name the frontmost (active) macOS app. No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'the active app name' };

    constructor(private readonly mac: MacAutomation) { }

    async plan(): Promise<ActionPreview> {
        return { summary: 'Would read which app is frontmost (read-only).', mutates: false };
    }

    async run(): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const script = 'tell application "System Events" to return name of first application process whose frontmost is true';
        try {
            const name = (await this.mac.runAppleScript(script)).trim();
            return name ? `The frontmost app is ${name}.` : 'Could not tell which app is frontmost.';
        } catch (e) {
            return describeMacError(e, 'read the active app');
        }
    }
}

/** T1: read the clipboard — huge for agent context ("use what I just copied"). Read-only. */
export class ClipboardReadCapability implements Capability {
    readonly name = 'mac.clipboard.read';
    readonly purpose = 'Read the current text on the macOS clipboard. No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'the clipboard' };

    constructor(private readonly mac: MacAutomation, private readonly maxChars = 4000) { }

    async plan(): Promise<ActionPreview> {
        return { summary: 'Would read the text currently on your clipboard (read-only).', mutates: false };
    }

    async run(): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        try {
            const text = await this.mac.runAppleScript('return (the clipboard as text)');
            if (!text) return 'The clipboard is empty (or holds no text).';
            return text.length > this.maxChars ? text.slice(0, this.maxChars) + '\n[…clipboard truncated]' : text;
        } catch (e) {
            return describeMacError(e, 'read the clipboard');
        }
    }
}

/** T2: open (launch/activate) an app by name. A side effect, so approved — reversible (just quit). */
export class OpenAppCapability implements Capability {
    readonly name = 'mac.app.open';
    readonly purpose = 'Open (launch and bring to front) a macOS app. Input: the app name, e.g. "Safari".';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the desktop (launches an app)' };

    constructor(private readonly mac: MacAutomation) { }

    async plan(input: string): Promise<ActionPreview> {
        const app = input.trim();
        if (!app) return { summary: 'Input is the app name to open.', mutates: false };
        return { summary: `Open "${app}" and bring it to the front (quit it to undo).`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const app = input.trim();
        if (!app) return 'Nothing to open — the app name is empty.';
        // `tell application "<name>" to activate` launches if needed and focuses. The name is
        // escaped into the string literal; a nonexistent app surfaces a clean AppleScript error.
        const script = `tell application "${escapeAppleScriptString(app)}" to activate`;
        try {
            await this.mac.runAppleScript(script);
            return `Opened "${app}".`;
        } catch (e) {
            const msg = (e as Error)?.message ?? '';
            if (/Can’t get application|isn't running|-1728|-10814|not found/i.test(msg)) {
                return `Couldn't find an app named "${app}".`;
            }
            return describeMacError(e, `open "${app}"`);
        }
    }
}

/** T2: create a Note with a title/body. A create — reversible (delete the note). Approved. */
export class NoteCreateCapability implements Capability {
    readonly name = 'mac.notes.create';
    readonly purpose = 'Create a note in macOS Notes. Input: the note text (first line becomes the title).';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'macOS Notes' };

    constructor(private readonly mac: MacAutomation) { }

    async plan(input: string): Promise<ActionPreview> {
        const body = input.trim();
        if (!body) return { summary: 'Input is the note text.', mutates: false };
        const title = body.split('\n')[0];
        const shown = title.length > 60 ? title.slice(0, 60) + '…' : title;
        return { summary: `Create a note "${shown}" (delete it in Notes to undo).`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const body = input.trim();
        if (!body) return 'Nothing to write — the note text is empty.';
        const escaped = escapeAppleScriptString(body);
        const script = [
            'tell application "Notes"',
            `  make new note at folder "Notes" of account "iCloud" with properties {body:"${escaped}"}`,
            'end tell',
            'return "ok"',
        ].join('\n');
        // The iCloud account/folder isn't guaranteed; fall back to the default container.
        const fallback = [
            'tell application "Notes"',
            `  make new note with properties {body:"${escaped}"}`,
            'end tell',
            'return "ok"',
        ].join('\n');
        const title = body.split('\n')[0];
        const shown = title.length > 60 ? title.slice(0, 60) + '…' : title;
        try {
            await this.mac.runAppleScript(script);
            return `Created a note "${shown}".`;
        } catch {
            try {
                await this.mac.runAppleScript(fallback);
                return `Created a note "${shown}".`;
            } catch (e) {
                return describeMacError(e, 'create the note');
            }
        }
    }

    /** Undo = delete the note(s) whose name matches the created title (first line of the input). */
    async undo(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const title = input.trim().split('\n')[0];
        const escaped = escapeAppleScriptString(title);
        const script = [
            'tell application "Notes"',
            `  delete (every note whose name is "${escaped}")`,
            'end tell',
            'return "ok"',
        ].join('\n');
        try {
            await this.mac.runAppleScript(script);
            const shown = title.length > 60 ? title.slice(0, 60) + '…' : title;
            return `Removed the note "${shown}".`;
        } catch (e) {
            return describeMacError(e, 'remove the note');
        }
    }
}

/** T2: open a URL in the default browser. Common, low-stakes, reversible (close the tab). */
export class OpenURLCapability implements Capability {
    readonly name = 'mac.safari.openURL';
    readonly purpose = 'Open a web URL in the browser. Input: an http(s) URL.';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'the browser (opens a page)' };

    constructor(private readonly mac: MacAutomation) { }

    /** Only http(s), no whitespace — a URL is not a place for AppleScript/shell surprises. */
    private valid(url: string): boolean {
        return /^https?:\/\/[^\s"]+$/i.test(url.trim());
    }

    async plan(input: string): Promise<ActionPreview> {
        const url = input.trim();
        if (!this.valid(url)) return { summary: 'Input must be an http(s) URL.', mutates: false };
        return { summary: `Open ${url} in the browser.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const url = input.trim();
        if (!this.valid(url)) return 'Input must be an http(s) URL (no spaces).';
        const script = `open location "${escapeAppleScriptString(url)}"`;
        try {
            await this.mac.runAppleScript(script);
            return `Opened ${url}.`;
        } catch (e) {
            return describeMacError(e, 'open the URL');
        }
    }
}

/**
 * T2: compose a Mail DRAFT — the Cowork-competitor sweet spot: it writes the email and shows it,
 * but NEVER sends (send is T4 / blocked-adjacent — a human hits send). Input:
 * "to: a@b.com | subject: … | body: …" (subject/body optional).
 */
export class MailDraftCapability implements Capability {
    readonly name = 'mac.mail.draft';
    readonly purpose = 'Draft an email in Mail (does NOT send). Input: "to: <address> | subject: <s> | body: <b>".';
    readonly tier = CapabilityTier.ReversibleWrite;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'Mail (a draft — never sent)' };

    constructor(private readonly mac: MacAutomation) { }

    private parse(input: string): { to: string; subject: string; body: string } | null {
        const fields: Record<string, string> = {};
        for (const part of input.split('|')) {
            const idx = part.indexOf(':');
            if (idx < 0) continue;
            fields[part.slice(0, idx).trim().toLowerCase()] = part.slice(idx + 1).trim();
        }
        const to = fields['to'] ?? '';
        if (!/^[^\s@"]+@[^\s@"]+\.[^\s@"]+$/.test(to)) return null;   // one plausible address
        return { to, subject: fields['subject'] ?? '', body: fields['body'] ?? '' };
    }

    async plan(input: string): Promise<ActionPreview> {
        const f = this.parse(input);
        if (!f) return { summary: 'Input must include a valid "to: <address>".', mutates: false };
        const subj = f.subject ? ` "${f.subject}"` : '';
        return { summary: `Draft an email to ${f.to}${subj} — it will NOT be sent; you review and send it yourself.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const f = this.parse(input);
        if (!f) return 'Input must include a valid "to: <address>".';
        const script = [
            'tell application "Mail"',
            `  set msg to make new outgoing message with properties {subject:"${escapeAppleScriptString(f.subject)}", content:"${escapeAppleScriptString(f.body)}", visible:true}`,
            `  tell msg to make new to recipient with properties {address:"${escapeAppleScriptString(f.to)}"}`,
            'end tell',
            'return "ok"',
            // Deliberately NO `send msg` — drafting is T2, sending is a human decision.
        ].join('\n');
        try {
            await this.mac.runAppleScript(script);
            return `Drafted an email to ${f.to} (open in Mail, not sent — review and send it yourself).`;
        } catch (e) {
            return describeMacError(e, 'draft the email');
        }
    }
}

/** T1: list the user's Apple Shortcuts by name — perception for `mac.shortcuts.run` (the model
 *  names what it can see, exactly like fs.list → fs.move and app.observe → app.tap). Read-only. */
export class ShortcutListCapability implements Capability {
    readonly name = 'mac.shortcuts.list';
    readonly purpose = 'List the names of your Apple Shortcuts. No input.';
    readonly tier = CapabilityTier.ReadOnly;
    readonly blastRadius: BlastRadius = { kind: 'read', resource: 'your Shortcuts library (names)' };

    constructor(private readonly mac: MacAutomation, private readonly maxNames = 200) { }

    async plan(): Promise<ActionPreview> {
        return { summary: 'Would list the names of your Apple Shortcuts (read-only).', mutates: false };
    }

    async run(): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const script = [
            'set out to ""',
            'tell application "Shortcuts Events"',
            '  repeat with s in shortcuts',
            '    set out to out & (name of s) & linefeed',
            '  end repeat',
            'end tell',
            'return out',
        ].join('\n');
        try {
            const names = (await this.mac.runAppleScript(script)).split('\n').map(n => n.trim()).filter(Boolean);
            if (names.length === 0) return 'You have no Apple Shortcuts yet.';
            const shown = names.slice(0, this.maxNames);
            return shown.join('\n') + (names.length > this.maxNames ? `\n[…${names.length - this.maxNames} more]` : '');
        } catch (e) {
            return describeMacError(e, 'list your Shortcuts');
        }
    }
}

/**
 * T3: run one of the user's EXISTING Apple Shortcuts by name — the lodestar (§1: "Apple bought
 * Workflow, not an AI that clicks things"). This is how "anything possible in macOS" is reached
 * safely: it invokes a shortcut the USER already authored, BY NAME, behind per-run approval —
 * never a "run arbitrary script" hole (it can't create or edit a shortcut, only call one that
 * exists). The shortcut's own effects are arbitrary, so this is T3 with a truthful preview and no
 * undo. Input: the shortcut name, optionally "<name> | <input text>" to pass it text.
 * (Note: a shortcut named with a blocklisted word — e.g. "Pay Rent" — is refused at the gate;
 * that's the same conservative tradeoff every capability has, and the user sees it in `history`.)
 */
export class ShortcutRunCapability implements Capability {
    readonly name = 'mac.shortcuts.run';
    readonly purpose = 'Run one of your Apple Shortcuts by name. Input: the shortcut name, or "<name> | <input text>".';
    readonly tier = CapabilityTier.AppAction;
    readonly blastRadius: BlastRadius = { kind: 'write', resource: 'your Shortcuts (runs a shortcut you built)' };

    constructor(private readonly mac: MacAutomation, private readonly maxChars = 4000) { }

    private parse(input: string): { name: string; text?: string } | null {
        const raw = input.trim();
        if (!raw) return null;
        const idx = raw.indexOf('|');
        if (idx < 0) return { name: raw };
        const name = raw.slice(0, idx).trim();
        const text = raw.slice(idx + 1).trim();
        return name ? (text ? { name, text } : { name }) : null;
    }

    async plan(input: string): Promise<ActionPreview> {
        const f = this.parse(input);
        if (!f) return { summary: 'Input is the shortcut name (use `mac.shortcuts.list` to see them).', mutates: false };
        const withText = f.text ? ` with input "${f.text.length > 40 ? f.text.slice(0, 40) + '…' : f.text}"` : '';
        return { summary: `Run your shortcut "${f.name}"${withText} — it does whatever you built it to do.`, mutates: true };
    }

    async run(input: string): Promise<string> {
        if (!this.mac.available()) return NOT_MAC;
        const f = this.parse(input);
        if (!f) return 'Input is the shortcut name — see `mac.shortcuts.list` for what you have.';
        const invoke = f.text
            ? `run shortcut "${escapeAppleScriptString(f.name)}" with input "${escapeAppleScriptString(f.text)}"`
            : `run shortcut "${escapeAppleScriptString(f.name)}"`;
        const script = [
            'tell application "Shortcuts Events"',
            `  set outVal to ${invoke}`,
            'end tell',
            'if outVal is missing value then return ""',
            'try',
            '  return (outVal as text)',
            'on error',
            '  return ""',
            'end try',
        ].join('\n');
        try {
            const out = (await this.mac.runAppleScript(script)).trim();
            if (!out) return `Ran your shortcut "${f.name}".`;
            const shown = out.length > this.maxChars ? out.slice(0, this.maxChars) + '\n[…output truncated]' : out;
            return `Ran your shortcut "${f.name}". It returned:\n${shown}`;
        } catch (e) {
            const msg = (e as Error)?.message ?? '';
            if (/Can’t get shortcut|not found|missing value|-1728/i.test(msg)) {
                return `No shortcut named "${f.name}". Use \`mac.shortcuts.list\` to see yours.`;
            }
            return describeMacError(e, `run the shortcut "${f.name}"`);
        }
    }
}

function describeMacError(e: unknown, action: string): string {
    const code = (e as { code?: string })?.code;
    if (code === 'MAC_ONLY') return NOT_MAC;
    if (code === 'MAC_TIMEOUT') return `Timed out trying to ${action}.`;
    // A first automation attempt often trips the macOS Automation permission prompt.
    const msg = (e as Error)?.message ?? '';
    if (/not allowed|Not authori|-1743|assistive access/i.test(msg)) {
        return `macOS blocked the action — grant Quenderin permission to control the app in System Settings › Privacy & Security › Automation, then try again.`;
    }
    return `Couldn't ${action}: ${msg || String(e)}`;
}

/** The macOS toolkit — grows as capabilities are added; the spine stays fixed. */
export function macCapabilities(mac: MacAutomation): Capability[] {
    return [
        // Perception (T1 — no approval)
        new FrontAppCapability(mac),
        new ClipboardReadCapability(mac),
        new CalendarTodayCapability(mac),
        new ShortcutListCapability(mac),
        // Action (T2 — per-run approval)
        new OpenAppCapability(mac),
        new OpenURLCapability(mac),
        new NoteCreateCapability(mac),
        new ReminderAddCapability(mac),
        new CalendarAddCapability(mac),
        new MailDraftCapability(mac),   // drafts, never sends
        // The Shortcuts library (T3 — per-run approval): the user's whole automation surface
        new ShortcutRunCapability(mac),
    ];
}
