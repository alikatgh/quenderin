import { describe, it, expect } from 'vitest';
import { hashPassphrase, isPassphraseHash } from '../ui/src/lib/passphrase.js';

/**
 * Q-530: the privacy-lock passphrase used to be persisted to localStorage as PLAINTEXT — hashing it only
 * at compare-time in PrivacyLock was theatre, since the plaintext was already sitting in storage. The
 * fix persists ONLY the SHA-256 hash (SettingsArea hashes on save; App migrates legacy plaintext once).
 * These pin the hashing helper both sides import so the stored format can't drift.
 */
describe('passphrase hashing (Q-530)', () => {
    it('returns a stable 64-char lowercase-hex SHA-256 digest', async () => {
        const h = await hashPassphrase('correct horse battery staple');
        expect(h).toMatch(/^[0-9a-f]{64}$/);
        // Known SHA-256("abc") vector — catches any change to algorithm or text encoding.
        expect(await hashPassphrase('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
        // Deterministic and input-sensitive.
        expect(await hashPassphrase('x')).toBe(await hashPassphrase('x'));
        expect(await hashPassphrase('x')).not.toBe(await hashPassphrase('y'));
    });

    it('the persisted value is never the plaintext', async () => {
        const secret = 'my-secret-passphrase';
        const stored = await hashPassphrase(secret);
        expect(stored).not.toBe(secret);
        expect(stored).not.toContain(secret);
    });

    it('isPassphraseHash tells a stored hash apart from a legacy plaintext value', async () => {
        expect(isPassphraseHash(await hashPassphrase('anything'))).toBe(true);
        expect(isPassphraseHash('hunter2')).toBe(false);        // legacy plaintext, pre-Q-530
        expect(isPassphraseHash('')).toBe(false);
        expect(isPassphraseHash('ABC123')).toBe(false);         // too short / uppercase
        expect(isPassphraseHash('g'.repeat(64))).toBe(false);   // 64 chars but not hex
    });
});
