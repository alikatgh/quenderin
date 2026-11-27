import { describe, it, expect, vi } from 'vitest';
import fsSync from 'fs';
import type { AddressInfo } from 'net';
import { createApp } from '../src/app.js';
import type { LlmService } from '../src/services/llm.service.js';
import logger from '../src/utils/logger.js';
import { localRequest } from './helpers/localHttp.js';

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
    localRequest(`${base}/api/models/switch`, {
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

    it('requires authentication for GET and HEAD on /api/models/catalog regardless of URL case', async () => {
        await withApp(fakeLlm(), async (base) => {
            expect((await localRequest(`${base}/api/models/catalog`)).status).toBe(401);
            expect((await localRequest(`${base}/api/models/catalog`, { method: 'HEAD' })).status).toBe(401);
            expect((await localRequest(`${base}/API/MODELS/CATALOG`)).status).toBe(401);
            expect((await localRequest(`${base}/API/MODELS/CATALOG`, { method: 'HEAD' })).status).toBe(401);
        });
    });

    it('catalog response carries activeModelId for the Active badge when authorized', async () => {
        await withApp(fakeLlm(), async (base) => {
            const res = await localRequest(`${base}/api/models/catalog`, {
                headers: { 'X-Auth-Token': 'secret-token' },
            });
            expect(res.status).toBe(200);
            const body = await res.json();
            expect(body.activeModelId).toBe('qwen3-4b');
            expect(Array.isArray(body.catalog)).toBe(true);
            const bonsai = body.catalog.find((model: { id: string }) => model.id === 'bonsai2-27b');
            expect(bonsai.runtimeCompatible).toBe(false);
            expect(bonsai.runtimeMessage).toContain('Prism llama.cpp');
        });
    });

    it('rejects an unsupported direct switch before changing the selected model', async () => {
        const switchModel = vi.fn();
        await withApp(fakeLlm({ switchModel }), async base => {
            const res = await post(base, { modelId: 'bonsai2-27b' }, 'secret-token');
            expect(res.status).toBe(409);
            expect((await res.json()).code).toBe('MODEL_RUNTIME_UNSUPPORTED');
        });
        expect(switchModel).not.toHaveBeenCalled();
    });

    it('rejects a compatible Prism switch when the mandatory RAM gate fails', async () => {
        const switchModel = vi.fn();
        await withApp(fakeLlm({
            switchModel,
            checkModelRuntime: async () => ({ canLoad: true, message: 'Pinned Prism addon installed.' }),
            checkModelMemory: async () => ({ canLoad: false, message: 'Insufficient available memory.' }),
        }), async base => {
            const res = await post(base, { modelId: 'bonsai2-27b' }, 'secret-token');
            expect(res.status).toBe(409);
            expect((await res.json()).code).toBe('MODEL_MEMORY_UNSAFE');
        });
        expect(switchModel).not.toHaveBeenCalled();
    });
});

describe('POST /api/models/download runtime compatibility', () => {
    function download(base: string) {
        return localRequest(`${base}/api/models/download`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Auth-Token': 'secret-token' },
            body: JSON.stringify({ modelId: 'bonsai2-27b' }),
        });
    }

    it('returns a clear failure instead of claiming an unsupported download started', async () => {
        const downloadModel = vi.fn();
        await withApp(fakeLlm({ downloadModel }), async base => {
            const res = await download(base);
            expect(res.status).toBe(409);
            expect((await res.json()).code).toBe('MODEL_RUNTIME_UNSUPPORTED');
        });
        expect(downloadModel).not.toHaveBeenCalled();
    });

    it('permits the request when the service verifies a compatible installed addon', async () => {
        const downloadModel = vi.fn().mockResolvedValue(undefined);
        await withApp(fakeLlm({
            downloadModel,
            checkModelRuntime: async () => ({ canLoad: true, message: 'Pinned Prism addon installed.' }),
        }), async base => {
            const res = await download(base);
            expect(res.status).toBe(200);
            expect((await res.json()).modelId).toBe('bonsai2-27b');
        });
        expect(downloadModel).toHaveBeenCalledWith('bonsai2-27b');
    });

    it('does not claim a low-memory Prism download started even when its addon is compatible', async () => {
        const downloadModel = vi.fn();
        await withApp(fakeLlm({
            downloadModel,
            checkModelRuntime: async () => ({ canLoad: true, message: 'Pinned Prism addon installed.' }),
            checkModelMemory: async () => ({ canLoad: false, message: 'Insufficient available memory.' }),
        }), async base => {
            const res = await download(base);
            expect(res.status).toBe(409);
            expect((await res.json()).code).toBe('MODEL_MEMORY_UNSAFE');
        });
        expect(downloadModel).not.toHaveBeenCalled();
    });

    it('rejects array parameter tampering for modelId on download and switch', async () => {
        const downloadModel = vi.fn();
        const switchModel = vi.fn();
        await withApp(fakeLlm({ downloadModel, switchModel }), async base => {
            const dl = await localRequest(`${base}/api/models/download`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Auth-Token': 'secret-token' },
                body: JSON.stringify({ modelId: ['llama32-1b', 'qwen3-4b'] }),
            });
            expect(dl.status).toBe(400);
            const sw = await post(base, { modelId: ['llama32-1b'] }, 'secret-token');
            expect(sw.status).toBe(400);
        });
        expect(downloadModel).not.toHaveBeenCalled();
        expect(switchModel).not.toHaveBeenCalled();
    });
});

describe('POST /api/models/download job coordination and activation', () => {
    const startDownload = (base: string, body: Record<string, unknown>) =>
        localRequest(`${base}/api/models/download`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Auth-Token': 'secret-token' },
            body: JSON.stringify(body),
        });

    it('returns 409 busy for a different model while a download slot is occupied', async () => {
        let finishDownload!: () => void;
        const downloadModel = vi.fn(() => new Promise<void>(resolve => { finishDownload = resolve; }));
        const switchModel = vi.fn(async () => {});
        await withApp(fakeLlm({ downloadModel, switchModel }), async base => {
            const first = await startDownload(base, { modelId: 'llama32-1b', activate: true });
            expect(first.status).toBe(200);
            expect(first.json()).toMatchObject({ modelId: 'llama32-1b', status: 'downloading', joined: false });

            const second = await startDownload(base, { modelId: 'qwen3-4b', activate: true });
            expect(second.status).toBe(409);
            expect(second.json()).toMatchObject({ code: 'MODEL_DOWNLOAD_BUSY', activeDownloadModelId: 'llama32-1b' });
            expect(downloadModel).toHaveBeenCalledTimes(1);

            finishDownload();
            await vi.waitFor(() => expect(switchModel).toHaveBeenCalledExactlyOnceWith('llama32-1b'));
        });
    });

    it('joins duplicate requests for the same in-flight model without losing activation', async () => {
        let finishDownload!: () => void;
        const downloadModel = vi.fn(() => new Promise<void>(resolve => { finishDownload = resolve; }));
        const switchModel = vi.fn(async () => {});
        await withApp(fakeLlm({ downloadModel, switchModel }), async base => {
            const first = await startDownload(base, { modelId: 'llama32-1b', activate: true });
            expect(first.status).toBe(200);
            const duplicate = await startDownload(base, { modelId: 'llama32-1b', activate: true });
            expect(duplicate.status).toBe(200);
            expect(duplicate.json()).toMatchObject({ modelId: 'llama32-1b', joined: true, activate: true });
            expect(downloadModel).toHaveBeenCalledTimes(1);

            finishDownload();
            await vi.waitFor(() => expect(switchModel).toHaveBeenCalledExactlyOnceWith('llama32-1b'));
        });
    });

    it('retains pending activation and retries when completion races with busy local work, or reports permanent failure', async () => {
        const previousRetry = process.env.QUENDERIN_MODEL_ACTIVATION_RETRY_MS;
        process.env.QUENDERIN_MODEL_ACTIVATION_RETRY_MS = '10';
        try {
            let attempts = 0;
            const switchModel = vi.fn(async () => {
                attempts++;
                if (attempts < 3) {
                    const err = new Error('INFERENCE_BUSY') as NodeJS.ErrnoException;
                    err.code = 'INFERENCE_BUSY';
                    throw err;
                }
            });
            const downloadModel = vi.fn(async () => {});
            await withApp(fakeLlm({ downloadModel, switchModel }), async base => {
                const res = await startDownload(base, { modelId: 'llama32-1b', activate: true });
                expect(res.status).toBe(200);
                await vi.waitFor(() => expect(switchModel).toHaveBeenCalledTimes(3));
                await vi.waitFor(async () => {
                    const catalogRes = await localRequest(`${base}/api/models/catalog`, {
                        headers: { 'X-Auth-Token': 'secret-token' },
                    });
                    expect(catalogRes.json()).toMatchObject({ pendingActivation: null });
                });
            });

            const loggerErrorSpy = vi.spyOn(logger, 'error').mockImplementation(() => {});
            const privatePathError = Object.assign(
                new Error("EACCES: permission denied, open '/Users/alice/.quenderin/models/private-secret.gguf'"),
                { code: 'EACCES' },
            );
            const failingSwitch = vi.fn(async () => { throw privatePathError; });
            try {
                await withApp(fakeLlm({ downloadModel, switchModel: failingSwitch }), async base => {
                    expect((await startDownload(base, { modelId: 'llama32-1b', activate: true })).status).toBe(200);
                    await vi.waitFor(async () => {
                        const catalogRes = await localRequest(`${base}/api/models/catalog`, {
                            headers: { 'X-Auth-Token': 'secret-token' },
                        });
                        const payload = catalogRes.json();
                        expect(payload).toMatchObject({
                            pendingActivation: {
                                modelId: 'llama32-1b',
                                status: 'failed',
                                code: 'MODEL_STORAGE_PERMISSION',
                            },
                        });
                        expect(payload.pendingActivation.error).not.toContain('/Users/alice');
                        expect(payload.pendingActivation.error).not.toContain('private-secret.gguf');
                    });
                });
                expect(loggerErrorSpy).toHaveBeenCalledWith('Background model activation failed:', privatePathError);

                const failingDownload = vi.fn(async () => {
                    throw new Error("Corrupted GGUF header at /home/bob/.quenderin/models/secret.gguf");
                });
                await withApp(fakeLlm({ downloadModel: failingDownload, switchModel }), async base => {
                    expect((await startDownload(base, { modelId: 'llama32-1b', activate: true })).status).toBe(200);
                    await vi.waitFor(async () => {
                        const catalogRes = await localRequest(`${base}/api/models/catalog`, {
                            headers: { 'X-Auth-Token': 'secret-token' },
                        });
                        const payload = catalogRes.json();
                        expect(payload).toMatchObject({
                            pendingActivation: {
                                modelId: 'llama32-1b',
                                status: 'failed',
                                code: 'MODEL_INTEGRITY_FAILED',
                            },
                        });
                        expect(payload.pendingActivation.error).not.toContain('/home/bob');
                        expect(payload.pendingActivation.error).not.toContain('secret.gguf');
                    });
                });
            } finally {
                loggerErrorSpy.mockRestore();
            }
        } finally {
            if (previousRetry === undefined) delete process.env.QUENDERIN_MODEL_ACTIVATION_RETRY_MS;
            else process.env.QUENDERIN_MODEL_ACTIVATION_RETRY_MS = previousRetry;
        }
    });

    it('updates activation revision on same-model join after an intervening switch, and discards if superseded again', async () => {
        let finishFirst!: () => void;
        const downloadModel = vi.fn(() => new Promise<void>(resolve => { finishFirst = resolve; }));
        const switchModel = vi.fn(async () => {});
        const existsSpy = vi.spyOn(fsSync, 'existsSync').mockReturnValue(true);
        try {
            await withApp(fakeLlm({ downloadModel, switchModel }), async base => {
                // 1. Download starts without activation (e.g. from Settings).
                const initial = await startDownload(base, { modelId: 'llama32-1b' });
                expect(initial.status).toBe(200);
                expect(initial.json()).toMatchObject({ modelId: 'llama32-1b', joined: false, activate: false });

                // 2. User switches to another installed model (advances modelChoiceRevision).
                const switched = await post(base, { modelId: 'qwen3-4b' }, 'secret-token');
                expect(switched.status).toBe(200);
                expect(switchModel).toHaveBeenCalledExactlyOnceWith('qwen3-4b');

                // 3. User joins the in-flight download and explicitly requests activation.
                const joined = await startDownload(base, { modelId: 'llama32-1b', activate: true });
                expect(joined.status).toBe(200);
                expect(joined.json()).toMatchObject({ modelId: 'llama32-1b', joined: true, activate: true });

                // 4. Download finishes: newly requested activation MUST run with the updated revision.
                finishFirst();
                await vi.waitFor(() => expect(switchModel).toHaveBeenNthCalledWith(2, 'llama32-1b'));
            });

            // Negative case: a switch AFTER the activation join supersedes the join.
            let finishSecond!: () => void;
            const downloadSecond = vi.fn(() => new Promise<void>(resolve => { finishSecond = resolve; }));
            const switchSecond = vi.fn(async () => {});
            await withApp(fakeLlm({ downloadModel: downloadSecond, switchModel: switchSecond }), async base => {
                expect((await startDownload(base, { modelId: 'llama32-1b' })).status).toBe(200);
                expect((await startDownload(base, { modelId: 'llama32-1b', activate: true })).status).toBe(200);
                expect((await post(base, { modelId: 'qwen3-4b' }, 'secret-token')).status).toBe(200);
                finishSecond();
                await new Promise(resolve => setTimeout(resolve, 30));
                expect(switchSecond).toHaveBeenCalledExactlyOnceWith('qwen3-4b');
            });
        } finally {
            existsSpy.mockRestore();
        }
    });
});
