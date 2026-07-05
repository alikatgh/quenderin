import { AuditEntry } from './capability.js';

/**
 * Render the audit ledger for `quenderin history` — the "review what it did" pillar of the trust
 * loop (stop · review · undo · consent · preview). A cloud agent can't show you a local, private,
 * tamper-evident log of what it did to YOUR machine; this reads the one we already persist to
 * ~/.quenderin/agent-ledger.jsonl. Kept pure (entries in → string out) so it's unit-testable
 * headless, with no clock or filesystem dependency — the CLI command is a thin reader over it.
 */

const RESET = '\x1b[0m';
const COLORS = {
    green: '\x1b[32m', red: '\x1b[31m', yellow: '\x1b[33m', dim: '\x1b[2m', bold: '\x1b[1m',
} as const;
type Color = keyof typeof COLORS;

interface DecisionStyle { symbol: string; color: Color; note: string; }

/** Map a ledger decision to a glyph + one-word plain-English meaning. Decisions like
 *  "blocked(pay)" carry the matched keyword, so match by prefix. */
function styleFor(decision: string): DecisionStyle {
    if (decision === 'allowed') return { symbol: '✓', color: 'green', note: 'ran' };
    if (decision === 'unverified') return { symbol: '✓', color: 'yellow', note: 'ran — unconfirmed' };
    if (decision.startsWith('blocked')) return { symbol: '✗', color: 'red', note: 'blocked by safety' };
    if (decision === 'declined') return { symbol: '✗', color: 'red', note: 'you declined' };
    if (decision === 'needsApproval') return { symbol: '○', color: 'yellow', note: 'no approval — skipped' };
    if (decision === 'needsConsent') return { symbol: '○', color: 'yellow', note: 'not permitted — skipped' };
    if (decision === 'dryRun') return { symbol: '◇', color: 'dim', note: 'dry run — would do, didn\'t' };
    if (decision === 'cancelled') return { symbol: '⊘', color: 'dim', note: 'stopped' };
    if (decision === 'bulkPaused') return { symbol: '⊘', color: 'yellow', note: 'bulk brake' };
    if (decision === 'error') return { symbol: '!', color: 'red', note: 'errored' };
    return { symbol: '·', color: 'dim', note: decision };
}

/** UTC minute, deterministic from the epoch ms (no timezone/locale variance — keeps tests stable). */
function stamp(ms: number): string {
    return new Date(ms).toISOString().slice(0, 16).replace('T', ' ');
}

export interface HistoryOptions {
    /** How many of the most recent entries to render (default 20). */
    limit?: number;
    /** Emit ANSI colour (default off — on for a TTY, off when piped or under test). */
    color?: boolean;
}

/** Render the ledger newest-first. Returns a ready-to-print block (no surrounding blank lines). */
export function formatHistory(entries: AuditEntry[], opts: HistoryOptions = {}): string {
    const color = opts.color ?? false;
    const paint = (s: string, c: Color) => (color ? `${COLORS[c]}${s}${RESET}` : s);
    if (entries.length === 0) {
        return 'No agent history yet. Run `quenderin do "<goal>"` to start.';
    }

    const limit = Math.max(1, opts.limit ?? 20);
    const newestFirst = [...entries].sort((a, b) => b.timestampMs - a.timestampMs);
    const shown = newestFirst.slice(0, limit);

    const lines: string[] = [];
    let lastGoal: string | null | undefined = Symbol('start') as unknown as string;   // force a header on the first row
    for (const e of shown) {
        // Group by task: print a "Task:" header whenever the goal changes between adjacent rows.
        // Each `quenderin do` is one process = one goal, so a task's actions are contiguous. This is
        // the structured, per-task local audit a cloud agent's flat chat log can't give you.
        const goal = e.goal?.trim() || null;
        if (goal !== lastGoal) {
            if (lines.length > 0) lines.push('');
            lines.push(goal ? paint(`Task: ${goal}`, 'bold') : paint('(no task recorded)', 'dim'));
            lastGoal = goal;
        }
        const st = styleFor(e.decision);
        lines.push(`  ${paint(stamp(e.timestampMs), 'dim')}  ${paint(st.symbol, st.color)} ${e.capability}${paint(`  ${st.note}`, 'dim')}`);
        const input = e.input?.trim();
        if (input) lines.push(paint(`        ${input}`, 'dim'));
        const outcome = e.outcome?.trim();
        if (outcome) {
            // Keep a multi-line outcome (e.g. a directory listing) aligned under the arrow.
            const [first, ...rest] = outcome.split('\n');
            lines.push(paint(`        → ${first}`, 'dim'));
            for (const r of rest) lines.push(paint(`          ${r}`, 'dim'));
        }
    }
    lines.push('');

    const hidden = newestFirst.length - shown.length;
    if (hidden > 0) lines.push(paint(`  …${hidden} older ${hidden === 1 ? 'entry' : 'entries'} (use --limit).`, 'dim'));

    const ran = entries.filter(e => e.decision === 'allowed' || e.decision === 'unverified').length;
    lines.push(paint(`  ${entries.length} logged · ${ran} ran · everything stayed on this machine.`, 'dim'));

    return lines.join('\n');
}
