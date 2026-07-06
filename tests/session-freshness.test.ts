import { describe, it, expect, vi, afterEach } from 'vitest';
import { SessionService } from '../src/services/session.service.js';

/**
 * Q-297: GET /api/sessions/:id calls loadSession(), which read the on-disk copy. But the ACTIVE
 * session lives in memory and only reaches disk on a debounced flush, so fetching the current session
 * returned a STALE transcript (missing the newest messages). loadSession now serves the in-memory copy
 * for the active id. Fake timers freeze the flush so this test does no disk I/O.
 */
describe('SessionService.loadSession freshness (Q-297)', () => {
    afterEach(() => vi.useRealTimers());

    it('serves the live in-memory transcript for the active id, not the un-flushed disk copy', () => {
        vi.useFakeTimers();
        const svc = new SessionService();
        const id = svc.activeSessionId();
        svc.addMessage('user', 'fresh message not yet flushed');

        const loaded = svc.loadSession(id);
        expect(loaded).not.toBeNull();
        expect(loaded!.id).toBe(id);
        expect(loaded!.messages.map(m => m.content)).toContain('fresh message not yet flushed');
    });
});
