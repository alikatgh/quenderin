/**
 * The canonical agent safety blocklist for the desktop (TypeScript). Twin of
 * shared/safety-blocklist.json — kept in exact set parity with the Swift/Kotlin lists by
 * scripts/check_safety_parity.py in CI (the three lists had silently drifted — audit Q-014 /
 * AGENT_AUTONOMY_PLAN Milestone 0). Never remove entries; add only.
 *
 * This is the ONE TypeScript source of the list (the parity script reads it here); ActionExecutor
 * and the capability runner both import from it, so device-driving and file capabilities can never
 * disagree about what's blocked.
 */
export const AGENT_BLOCKLIST = [
    // Financial
    'pay', 'payment', 'purchase', 'buy', 'buy now', 'checkout', 'transfer', 'send money',
    'wire', 'bank', 'credit card', 'cvv', 'venmo', 'paypal',
    'confirm purchase', 'confirm payment', 'place order', 'withdraw',
    // Destructive
    'delete', 'erase', 'format', 'wipe', 'factory reset', 'uninstall', 'remove all',
    'revoke', 'deactivate',
    // Credentials / sensitive
    'password', 'passcode', 'pin', 'ssn', 'social security', 'private key', 'seed phrase',
];

/**
 * The blocked keyword `raw` touches, or undefined. Single-word keywords match on word
 * boundaries — camelCase and separators (`_`, `-`) are split — so a resourceId like
 * "confirm_transfer_btn" / "confirmTransferBtn" still matches 'transfer' (H10) while 'pin' never
 * fires on "spinner" and 'bank' never on "bankruptcy". Multi-word phrases match as substrings
 * (identical semantics to the Swift/Kotlin twins).
 */
export function matchedBlockedKeyword(raw: string): string | undefined {
    const spaced = raw.replace(/([a-z0-9])([A-Z])/g, '$1 $2'); // camelCase → spaced before lowercasing
    const lower = spaced.toLowerCase();
    const tokens = new Set(lower.split(/[^a-z0-9]+/).filter(Boolean));
    for (const kw of AGENT_BLOCKLIST) {
        if (kw.includes(' ')) {
            if (lower.includes(kw)) return kw;
        } else if (tokens.has(kw)) {
            return kw;
        }
    }
    return undefined;
}
