import { AddressInfo } from 'net';
import { describe, expect, it } from 'vitest';
import { getRecommendedModelIdForTotalRam } from '../src/constants.js';
import { createApp } from '../src/app.js';

describe('getRecommendedModelIdForTotalRam', () => {
    it('recommends ultra-light Q2_K below 1.5GB', () => {
        expect(getRecommendedModelIdForTotalRam(0.5)).toBe('llama32-1b-q2');
        expect(getRecommendedModelIdForTotalRam(1)).toBe('llama32-1b-q2');
        expect(getRecommendedModelIdForTotalRam(1.49)).toBe('llama32-1b-q2');
    });

    it('recommends 1B from 1.5GB up to under 3GB', () => {
        expect(getRecommendedModelIdForTotalRam(1.5)).toBe('llama32-1b');
        expect(getRecommendedModelIdForTotalRam(2.99)).toBe('llama32-1b');
    });

    it('recommends 3B from 3GB up to under 6GB', () => {
        expect(getRecommendedModelIdForTotalRam(3)).toBe('llama32-3b');
        expect(getRecommendedModelIdForTotalRam(5.99)).toBe('llama32-3b');
    });

    it('recommends 8B at 6GB and above', () => {
        expect(getRecommendedModelIdForTotalRam(6)).toBe('llama3-8b');
        expect(getRecommendedModelIdForTotalRam(18)).toBe('llama3-8b');
    });

    it('keeps /health recommendation and /api/models/download default in sync', async () => {
        let requestedModelId: string | undefined;

        const llmServiceMock = {
            downloadModel: async (modelId?: string) => {
                requestedModelId = modelId;
            },
            getActivePresetId: () => 'general',
        } as any;

        const app = createApp(undefined, undefined, llmServiceMock);
        const server = app.listen(0);
        const port = (server.address() as AddressInfo).port;

        try {
            const healthRes = await fetch(`http://127.0.0.1:${port}/health`);
            expect(healthRes.ok).toBe(true);
            const health = await healthRes.json() as { recommendedModelId: string };

            const downloadRes = await fetch(`http://127.0.0.1:${port}/api/models/download`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({}),
            });
            expect(downloadRes.ok).toBe(true);
            const download = await downloadRes.json() as { modelId: string };

            expect(download.modelId).toBe(health.recommendedModelId);
            expect(requestedModelId).toBe(health.recommendedModelId);
        } finally {
            await new Promise<void>((resolve, reject) => {
                server.close((err) => {
                    if (err) reject(err);
                    else resolve();
                });
            });
        }
    });
});
