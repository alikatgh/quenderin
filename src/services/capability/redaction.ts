/**
 * Mask values that look like credentials before they're written to the on-disk audit ledger — a
 * privacy defense-in-depth. The action still used the REAL value; only the persisted log row is
 * masked, so `quenderin history` (and the ~/.quenderin/agent-ledger.jsonl file) never becomes a
 * place a leaked secret lives. Deliberately HIGH-PRECISION: it targets recognizable credential
 * shapes (provider key prefixes, bearer tokens, `password=…`), not any long string, so the audit
 * stays readable and a file named like a hash isn't mangled.
 */
const MASK = '…redacted';

const PATTERNS: Array<[RegExp, string]> = [
    // Provider API keys with a known prefix: sk-…, pk-…, rk-… (OpenAI/Stripe-style).
    [/\b(sk|pk|rk)-[A-Za-z0-9]{16,}/g, `$1-${MASK}`],
    // GitHub tokens: ghp_/gho_/ghs_/ghu_ …
    [/\bgh[posu]_[A-Za-z0-9]{16,}/g, `gh_${MASK}`],
    // Slack tokens: xoxb-/xoxp-/xoxa-/xoxr-/xoxs- …
    [/\bxox[baprs]-[A-Za-z0-9-]{10,}/g, `xox-${MASK}`],
    // AWS access key IDs.
    [/\bAKIA[0-9A-Z]{16}\b/g, `AKIA${MASK}`],
    // Bearer tokens.
    [/\b[Bb]earer\s+[A-Za-z0-9._-]{16,}/g, `Bearer ${MASK}`],
    // key/password/secret/token = <value> (mask the value, keep the label so the audit still reads).
    [/\b(password|passwd|pwd|secret|token|api[_-]?key)(\s*[:=]\s*)(\S+)/gi, `$1$2${MASK}`],
];

/** Return `text` with credential-shaped substrings masked. Safe on empty/undefined-ish input. */
export function redactSecrets(text: string): string {
    if (!text) return text;
    let out = text;
    for (const [re, repl] of PATTERNS) out = out.replace(re, repl);
    return out;
}
