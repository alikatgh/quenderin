import { Capability } from './capability.js';
import { MacAutomation } from './macAutomation.js';
import { macCapabilities } from './macCapabilities.js';
import { fileCapabilities } from './fileCapabilities.js';

/**
 * Cross-session undo — reverse the last `quenderin do` task even from a FRESH process (after the
 * run that made the changes has exited, or you said "no" then changed your mind, or it crashed).
 * The in-run `RunSession.undoAll()` only works while that process is alive; this replays a persisted
 * journal. A cloud agent can't offer transactional undo of your local machine at all, let alone an
 * hour later in a new session — this is the trust superpower, made durable.
 *
 * The journal stores only capability NAME + input (+ the workspace dir for fs.* actions, since a
 * file undo needs to know which folder). The replayer rebuilds the capability by name from the same
 * factories the agent uses, so reversal goes through the exact same `undo()` the live session would.
 */
export interface UndoAction {
    capability: string;
    input: string;
    /** The workspace folder for an fs.* action — required to rebuild the file capability. */
    workspace?: string;
}

/** Validate one persisted row (the journal is on disk — treat it as untrusted). */
export function isUndoAction(v: unknown): v is UndoAction {
    const a = v as Partial<UndoAction>;
    return typeof a?.capability === 'string' && typeof a?.input === 'string'
        && (a.workspace === undefined || typeof a.workspace === 'string');
}

/**
 * Reverse each action newest-first, rebuilding the capability by name. Best-effort, exactly like
 * the in-session undo: a failed or unrecognised reversal is reported but never stops the rest — the
 * user wants as much rolled back as possible. Returns one human sentence per action.
 */
export async function replayUndo(actions: UndoAction[], mac: MacAutomation): Promise<string> {
    if (actions.length === 0) return 'Nothing to undo — no recorded task.';
    const macByName = new Map<string, Capability>(macCapabilities(mac).map(c => [c.name, c]));
    const lines: string[] = [];
    for (let i = actions.length - 1; i >= 0; i--) {   // LIFO — reverse newest first
        const a = actions[i];
        let cap: Capability | undefined;
        if (a.capability.startsWith('fs.')) {
            if (!a.workspace) { lines.push(`Skipped ${a.capability} — its workspace wasn't recorded.`); continue; }
            const ws = a.workspace;
            cap = fileCapabilities(() => ws).find(c => c.name === a.capability);
        } else {
            cap = macByName.get(a.capability);
        }
        if (!cap?.undo) { lines.push(`Skipped ${a.capability} — nothing to reverse.`); continue; }
        try {
            lines.push(await cap.undo(a.input));
        } catch (e) {
            lines.push(`Couldn't undo ${a.capability}(${a.input}): ${String(e)}`);
        }
    }
    return lines.join('\n');
}
