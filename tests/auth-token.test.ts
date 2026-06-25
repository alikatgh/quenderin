import { describe, it, expect } from 'vitest';
import { generateAuthToken, timingSafeEqualStr, extractWsToken, isAuthorized } from '../src/security/authToken.js';

/** The local-server auth token (security audit HIGH #1). These pin the pure validation logic the WS
 *  upgrade + route middleware rely on; the main→preload→renderer delivery is verified live. */
describe('authToken', () => {
    it('generates a 64-hex-char (256-bit) random token, unique per call', () => {
        const a = generateAuthToken();
        const b = generateAuthToken();
        expect(a).toMatch(/^[0-9a-f]{64}$/);
        expect(a).not.toBe(b);
    });

    it('timingSafeEqualStr matches identical strings and rejects others (incl. unequal length)', () => {
        expect(timingSafeEqualStr('abc', 'abc')).toBe(true);
        expect(timingSafeEqualStr('abc', 'abd')).toBe(false);
        expect(timingSafeEqualStr('abc', 'abcd')).toBe(false);
        expect(timingSafeEqualStr('', '')).toBe(true);
    });

    it('extractWsToken pulls ?token= from a WS upgrade URL', () => {
        expect(extractWsToken('/ws?token=deadbeef')).toBe('deadbeef');
        expect(extractWsToken('/ws?foo=1&token=abc&bar=2')).toBe('abc');
        expect(extractWsToken('/ws')).toBeNull();
        expect(extractWsToken('')).toBeNull();
        expect(extractWsToken(undefined)).toBeNull();
    });

    it('isAuthorized requires a non-empty expected token and an exact match', () => {
        const token = generateAuthToken();
        expect(isAuthorized(token, token)).toBe(true);
        expect(isAuthorized(token + 'x', token)).toBe(false);
        expect(isAuthorized(null, token)).toBe(false);
        expect(isAuthorized(undefined, token)).toBe(false);
        expect(isAuthorized('anything', '')).toBe(false);   // unprovisioned expected → fail closed
    });
});
