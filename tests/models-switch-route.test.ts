import { describe, it, expect } from 'vitest';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';
import type { LlmService } from '../src/services/llm.service.js';

/**
 * r37: `POST /api/models/switch` became the ONE switch path (the WS twin was removed, r9-H1)
 * and the UI's Use button depends on its contract — but no test pinned it. These pin:
 * unknown id → 400, known-but-not-downloaded → 404 (never a silent success), auth required,
 * and the catalog response carrying `activeModelId` (what renders the Active badge).
 */
function fakeLlm(overrides: Partial<Record<string, unknown>> = {}) {
    return {
        switchModel: async () => { /* success */ },
        getActiveModelLabel: () => 'Test Model',
        getActiveModelId: () => 'qwen3-4b',
        getModelLifecycleInfo: () => ({ loadedModelId: null, isGenerating: false }),
        downloadModel: async () => { /* noop */ },
        ...overrides,
    } as unknown as LlmService;
}

async function withApp(llm: LlmService, fn: (base: string) => Promise<void>) {
    const app = createApp(undefined, undefined, llm, undefined, undefined, 'secret-token');
    const server = app.listen(0);
    const port = (server.address() as AddressInfo).port;
    try {
        await fn(`http://127.0.0.1:${port}`);
    } finally {
        await new Promise<void>((resolve) => server.close(() => resolve()));
    }
}

const post = (base: string, body: unknown, token?: string) =>
    fetch(`${base}/api/models/switch`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            ...(token ? { 'X-Auth-Token': token } : {}),
        },
        body: JSON.stringify(body),
    });

describe('POST /api/models/switch (the one switch path)', () => {
    it('requires the auth token (mutating route)', async () => {
        await withApp(fakeLlm(), async (base) => {
            const res = await post(base, { modelId: 'qwen3-4b' });
            expect(res.status).toBe(401);
        });
    });

    it('rejects an unknown modelId with 400, never a silent fallback', async () => {
        await withApp(fakeLlm(), async (base) => {
            const res = await post(base, { modelId: 'not-a-real-model' }, 'secret-token');
            expect(res.status).toBe(400);
            const body = await res.json();
            expect(body.error).toMatch(/unknown or missing/i);
        });
    });

    it('rejects a missing modelId with 400', async () => {
        await withApp(fakeLlm(), async (base) => {
            const res = await post(base, {}, 'secret-token');
            expect(res.status).toBe(400);
        });
    });

    it('404s a catalog model whose file is not on disk (download first)', async () => {
        await withApp(fakeLlm(), async (base) => {
            // qwen3-4b is a real catalog id; the test env has no ~/.quenderin model files.
            const res = await post(base, { modelId: 'qwen3-4b' }, 'secret-token');
            expect(res.status).toBe(404);
            const body = await res.json();
            expect(body.error).toMatch(/not found on disk/i);
        });
    });

    it('catalog response carries activeModelId for the Active badge', async () => {
        await withApp(fakeLlm(), async (base) => {
            const res = await fetch(`${base}/api/models/catalog`);
            expect(res.status).toBe(200);
            const body = await res.json();
            expect(body.activeModelId).toBe('qwen3-4b');
            expect(Array.isArray(body.catalog)).toBe(true);
        });
    });
});
