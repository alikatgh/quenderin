import { describe, it, expect } from 'vitest';
import { extractAndStripToken } from '../ui/src/lib/api.js';

/**
 * Q-525: the CLI/browser path delivers the per-launch auth token in `?token=`. authToken() now reads
 * it once and strips it from the URL (replaceState) so it doesn't linger in the address bar / history /
 * bookmarks. extractAndStripToken is the DOM-free core: pull the token, rebuild the URL without it.
 */
describe('extractAndStripToken (Q-525)', () => {
    it('extracts the token and removes it from the URL', () => {
        const { token, cleanUrl } = extractAndStripToken('?token=SECRET123', '/', '');
        expect(token).toBe('SECRET123');
        expect(cleanUrl).toBe('/');
        expect(cleanUrl).not.toContain('SECRET123');
    });

    it('preserves other query params and the hash', () => {
        const { token, cleanUrl } = extractAndStripToken('?token=abc&lang=fr', '/app', '#chat');
        expect(token).toBe('abc');
        expect(cleanUrl).toBe('/app?lang=fr#chat');
    });

    it('returns an empty token and the path unchanged when none is present', () => {
        const { token, cleanUrl } = extractAndStripToken('?lang=fr', '/x', '');
        expect(token).toBe('');
        expect(cleanUrl).toBe('/x?lang=fr');
    });
});
