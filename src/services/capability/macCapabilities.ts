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
        // Action (T2 — per-run approval)
        new OpenAppCapability(mac),
        new OpenURLCapability(mac),
        new NoteCreateCapability(mac),
        new ReminderAddCapability(mac),
        new MailDraftCapability(mac),   // drafts, never sends
    ];
}
