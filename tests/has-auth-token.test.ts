import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

/**
 * Q-526: hasAuthToken() lets the renderer detect the "no per-launch token" state and show a relaunch
 * banner instead of letting every protected route 401 opaquely. It reads the token from the same two
 * sources as apiFetch — the Electron preload (window.quenderinAuth) or the CLI/browser URL (?token=).
 * Each case gets a fresh module (resetModules) so the module-level token cache doesn't leak between them.
 */
const stubWindow = (w: Record<string, unknown>) =>
    vi.stubGlobal('window', { history: { replaceState: () => { /* noop */ } }, location: { search: '', pathname: '/', hash: '' }, ...w });

describe('hasAuthToken (Q-526)', () => {
    beforeEach(() => vi.resetModules());
    afterEach(() => vi.unstubAllGlobals());

    it('is FALSE when neither the preload nor a ?token= supplies one (the opaque-401 case)', async () => {
        stubWindow({ location: { search: '', pathname: '/', hash: '' } });
        const { hasAuthToken } = await import('../ui/src/lib/api.js');
        expect(hasAuthToken()).toBe(false);
    });

    it('is TRUE when the CLI/browser token is in the URL', async () => {
        stubWindow({ location: { search: '?token=SECRET123', pathname: '/', hash: '' } });
        const { hasAuthToken } = await import('../ui/src/lib/api.js');
        expect(hasAuthToken()).toBe(true);
    });

    it('is TRUE when the Electron preload supplies the token out-of-band', async () => {
        stubWindow({ quenderinAuth: { token: 'PRELOAD_TOKEN' } });
        const { hasAuthToken } = await import('../ui/src/lib/api.js');
        expect(hasAuthToken()).toBe(true);
    });
});
