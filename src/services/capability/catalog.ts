import { Capability, CapabilityTier } from './capability.js';

/**
 * Render the capability library for `quenderin capabilities` — the discovery front door to the
 * mission ("anything possible in macOS"): you can't ask for what you don't know the agent can do.
 * It also makes the governance model legible in a way a cloud agent's opaque "it does stuff" isn't:
 * every action is tiered (perception = no approval; actions = ask first, reversible where possible).
 * Pure (capabilities in → string out) so it's unit-testable headless; the CLI command is a thin
 * reader that instantiates the real library over it.
 */

const RESET = '\x1b[0m';
const COLORS = { bold: '\x1b[1m', dim: '\x1b[2m', teal: '\x1b[36m' } as const;
type Color = keyof typeof COLORS;

export interface CatalogOptions {
    /** Emit ANSI colour (default off — on for a TTY, off when piped or under test). */
    color?: boolean;
}

/** fs.* actions only work once a folder is granted, so flag them in the listing. */
function needsWorkspace(name: string): boolean {
    return name.startsWith('fs.');
}

export function formatCapabilities(capabilities: Capability[], opts: CatalogOptions = {}): string {
    const color = opts.color ?? false;
    const paint = (s: string, c: Color) => (color ? `${COLORS[c]}${s}${RESET}` : s);
    if (capabilities.length === 0) {
        return 'No capabilities available here. On macOS you get app control; add --workspace for file tasks.';
    }

    const pad = Math.min(22, capabilities.reduce((m, c) => Math.max(m, c.name.length), 0) + 2);
    const row = (c: Capability) => {
        const hint = needsWorkspace(c.name) ? paint('  (needs --workspace)', 'dim') : '';
        return `  ${paint(c.name.padEnd(pad), 'teal')}${c.purpose}${hint}`;
    };

    // T1 is perception (no approval); everything above asks first.
    const perception = capabilities.filter(c => c.tier === CapabilityTier.ReadOnly);
    const actions = capabilities.filter(c => c.tier > CapabilityTier.ReadOnly);

    const out: string[] = ['', paint('Quenderin can do these — every action asks before it changes anything.', 'bold')];
    if (perception.length) {
        out.push('', paint('PERCEPTION', 'bold') + paint('  — read-only, no approval', 'dim'));
        for (const c of perception) out.push(row(c));
    }
    if (actions.length) {
        out.push('', paint('ACTIONS', 'bold') + paint('  — asks approval; reversible where possible, and undoable with `quenderin undo`', 'dim'));
        for (const c of actions) out.push(row(c));
    }
    out.push('', paint('The library grows without bending the safety spine — this is the whole list, right now.', 'dim'), '');
    return out.join('\n');
}
