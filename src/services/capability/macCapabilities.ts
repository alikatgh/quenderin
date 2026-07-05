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
        new CalendarTodayCapability(mac),
        new ReminderAddCapability(mac),
    ];
}
