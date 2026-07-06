// Q-530: the privacy-lock passphrase must NEVER be persisted as plaintext. localStorage (and anyone
// with DOM/devtools/XSS access to it) only ever sees the SHA-256 hash produced here — the plaintext
// lives for the lifetime of a keystroke in a component's in-memory draft and is discarded on save.
// PrivacyLock and SettingsArea both import this single helper so the hash format can't drift.

/** SHA-256 hex digest of a passphrase. This is the ONLY representation of a passphrase we persist. */
export async function hashPassphrase(input: string): Promise<string> {
    const encoded = new TextEncoder().encode(input);
    const digest = await crypto.subtle.digest('SHA-256', encoded);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

/** A persisted passphrase value is a 64-char lowercase-hex SHA-256 digest. Anything else is a legacy
 *  PLAINTEXT value written before Q-530 — callers use this to migrate it (App) or compare it in a
 *  backward-compatible way (PrivacyLock) so an existing user is never locked out mid-migration. */
export function isPassphraseHash(value: string): boolean {
    return /^[0-9a-f]{64}$/.test(value);
}
