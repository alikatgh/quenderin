/**
 * Guards for the agent trust-loop control channel (pause / intervene / resume).
 *
 * `manualAction` (what the human tells the agent to do instead) is interpolated verbatim into the
 * LLM's action-history context on resume, so it's a prompt-injection surface: a non-string
 * (object/array/number) must never reach the prompt, and the length must be capped so a paste-bomb
 * can't blow the context budget. This was inlined in the HTTP `/api/agent/resume` handler (M7/L7);
 * Q-281 exposes the same control over WebSocket, so the guard lives here and BOTH transports call it
 * — one rule, one place, unit-tested without a server. Returns `undefined` (plain resume, no
 * override) for anything that isn't a non-empty string.
 */
export const MAX_MANUAL_ACTION_LEN = 4000;

export function sanitizeManualAction(raw: unknown): string | undefined {
    if (typeof raw !== 'string') return undefined;
    const trimmed = raw.slice(0, MAX_MANUAL_ACTION_LEN).trim();
    return trimmed.length > 0 ? trimmed : undefined;
}
