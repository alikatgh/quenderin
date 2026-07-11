import { describe, it, expect, vi } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';
import type { MemoryService } from '../src/services/memory.service.js';
import { localRequest } from './helpers/localHttp.js';

/**
 * Q-304/Q-422: the notes API had GET (list + read) and DELETE but no way to CREATE a note over HTTP,
 * even though MemoryService.saveNote() already existed. POST /api/notes now exposes it. It's a mutating
 * /api/ route, so the global auth gate covers it; a blank title is rejected before touching storage.
 */
describe('POST /api/notes (Q-304/422)', () => {
    async function withApp(memory: MemoryService, fn: (base: string) => Promise<void>) {
        const app = createApp(undefined as never, undefined as never, undefined as never, undefined as never, memory, 'secret-token');
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;
        try { await fn(`http://127.0.0.1:${port}`); }
        finally { await new Promise<void>((r) => server.close(() => r())); }
    }
    const AUTHED = { 'X-Auth-Token': 'secret-token', 'Content-Type': 'application/json' };

    it('creates a note via saveNote and returns 201', async () => {
        const saveNote = vi.fn().mockResolvedValue({ path: '/notes/My_Note.md' });
        await withApp({ saveNote } as unknown as MemoryService, async (base) => {
            const res = await localRequest(`${base}/api/notes`, { method: 'POST', headers: AUTHED, body: JSON.stringify({ title: 'My Note', content: 'hello' }) });
            expect(res.status).toBe(201);
            expect(saveNote).toHaveBeenCalledWith('My Note', 'hello');
        });
    });

    it('rejects a blank title with 400 and never touches storage', async () => {
        const saveNote = vi.fn();
        await withApp({ saveNote } as unknown as MemoryService, async (base) => {
            const res = await localRequest(`${base}/api/notes`, { method: 'POST', headers: AUTHED, body: JSON.stringify({ content: 'orphan' }) });
            expect(res.status).toBe(400);
            expect(saveNote).not.toHaveBeenCalled();
        });
    });

    it('requires the auth token (mutating route → 401 without it)', async () => {
        await withApp({ saveNote: vi.fn() } as unknown as MemoryService, async (base) => {
            const res = await localRequest(`${base}/api/notes`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title: 'x' }) });
            expect(res.status).toBe(401);
        });
    });
});
