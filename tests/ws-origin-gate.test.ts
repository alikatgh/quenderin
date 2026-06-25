import { describe, it, expect } from 'vitest';
import { isAllowedLocalWsOrigin } from '../src/websocket/index.js';

/**
 * The WS upgrade gate (security audit HIGH #2). A non-browser client (curl, a malicious local
 * process) used to get full agent control simply by omitting the Origin header; now a missing Origin
 * is rejected. (This is a hardening, not authentication — see the function's note; the real fix is a
 * per-launch token, audit HIGH #1.)
 */
describe('isAllowedLocalWsOrigin', () => {
    it('rejects a missing/empty Origin — the non-browser exploit path', () => {
        expect(isAllowedLocalWsOrigin(undefined)).toBe(false);
        expect(isAllowedLocalWsOrigin('')).toBe(false);
    });

    it('accepts local browser origins (the legitimate http-served renderer)', () => {
        for (const o of ['http://localhost:3000', 'http://127.0.0.1:5173', 'http://[::1]:8080']) {
            expect(isAllowedLocalWsOrigin(o)).toBe(true);
        }
    });

    it('rejects non-local, look-alike, and malformed origins', () => {
        for (const o of ['http://localhost.attacker.com', 'https://evil.com', 'null', 'not a url', 'file://']) {
            expect(isAllowedLocalWsOrigin(o)).toBe(false);
        }
    });
});
