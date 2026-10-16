import { describe, expect, it } from 'vitest';
import {
    getRecommendedModelIdForTotalRam,
    gpuOffloadFits,
    MODEL_CATALOG,
    modelPath,
    ALLOWED_CONTEXT_SIZES,
    MAX_GOAL_LENGTH,
    MAX_CHAT_LENGTH,
    MAX_ATTACHMENTS,
    MAX_ATTACHMENT_SIZE,
    MAX_SESSIONS,
    MAX_MESSAGES_PER_SESSION,
} from '../src/constants.js';

describe('MODEL_CATALOG', () => {
    it('has unique model IDs', () => {
        const ids = MODEL_CATALOG.map(m => m.id);
        expect(new Set(ids).size).toBe(ids.length);
    });

    it('has unique filenames', () => {
        const filenames = MODEL_CATALOG.map(m => m.filename);
        expect(new Set(filenames).size).toBe(filenames.length);
    });

    it('all models have positive RAM requirements', () => {
        for (const m of MODEL_CATALOG) {
            expect(m.ramGb).toBeGreaterThan(0);
        }
    });

    it('all models have valid quantization labels', () => {
        for (const m of MODEL_CATALOG) {
            // Q4_K_M / Q2_K …, plus i-quants and Unsloth dynamic ("UD-IQ3_XXS").
            expect(m.quantization).toMatch(/^(?:(UD-)?I?Q\d|PTQ1_0$)/);
        }
    });

    it('every model states its language support, honest about Russian', () => {
        // Russian-first user base: the info must exist on every entry, and the Llama 3.2
        // tier must say "no Russian" out loud rather than omit it.
        for (const m of MODEL_CATALOG) {
            expect(m.languages, `${m.id} must state languages`).toBeTruthy();
        }
        expect(MODEL_CATALOG.find(m => m.id === 'llama32-1b')!.languages).toContain('no Russian');
        expect(MODEL_CATALOG.find(m => m.id === 'qwen3-4b')!.languages).toMatch(/^Russian/);
    });

    it('paged-MoE entry budgets the RESIDENT set, not the file', () => {
        // qwen36-35b-a3b streams experts from disk via mmap: ramGb must reflect the
        // dense-spine + hot-experts working set (~5.5), NOT the 13.2 GB download —
        // the whole point is that a 16 GB machine can run it.
        const moe = MODEL_CATALOG.find(m => m.id === 'qwen36-35b-a3b')!;
        expect(moe).toBeDefined();
        expect(moe.ramGb).toBeLessThan(6);
        expect(moe.sizeLabel).toContain('13.2');
    });

    it('keeps the default and smallest entries while pinning the experimental Bonsai artifact', () => {
        expect(MODEL_CATALOG[0].id).toBe('qwen36-35b-a3b');
        expect(MODEL_CATALOG.at(-1)!.id).toBe('llama32-1b-q2');
        const bonsai = MODEL_CATALOG[1];
        expect(bonsai).toMatchObject({
            id: 'bonsai2-27b', label: 'Bonsai 2 27B (Experimental)',
            quantization: 'PTQ1_0', paramsBillions: 27.36, ramGb: 7,
            sizeLabel: '5.95 GB download', downloadBytes: 5946648928,
            languages: 'See model card',
            sha256: '53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3',
        });
        expect(bonsai.url).toContain('/resolve/b072e1d3b35a0a630cece372c2127528e0994386/');
        expect(MODEL_CATALOG[5].id).toBe('qwen3-14b');
    });

    it.each([
        ['bonsai2-2b', 1.88, 1.5, 429183456, '683f7be2629342a50987627b40881e54761a2430', '36061ad406df8a4903a6db005be350c50fabfaf717f9ef0acf4b76adcd9929fa'],
        ['bonsai2-4b', 4.21, 2.5, 949549920, '8d6557168168f91ea6697a4a49ed2ef622b53adb', '56711263ec9a9ffeaa74a3a0e58dece8127cf9268404746c721113ca76994d60'],
        ['bonsai2-9b', 8.95, 4, 1997486976, '5b2abb02362efbed46bbe204014b02837778b2c2', '3561df7ac7d26a71ffa991ac2db740b10841c3a350aa2676ccd3ff5d428b4e8b'],
    ])('pins the smaller manual experimental artifact %s', (id, paramsBillions, ramGb, downloadBytes, revision, sha256) => {
        const entry = MODEL_CATALOG.find(model => model.id === id)!;
        expect(entry).toMatchObject({ paramsBillions, ramGb, downloadBytes, sha256, quantization: 'PTQ1_0' });
        expect(entry.label).toContain('(Experimental)');
        expect(entry.url).toContain(`/resolve/${revision}/${entry.filename}?download=true`);
        expect(entry.ramGb).toBeGreaterThan(Number(downloadBytes) / 1e9);
    });
});

describe('gpuOffloadFits', () => {
    it('offloads when the file fits the GPU budget', () => {
        expect(gpuOffloadFits(9.0, 16)).toBe(true);    // dense 14B on 16 GB
        expect(gpuOffloadFits(13.2, 32)).toBe(true);   // paged MoE on a big machine
    });

    it('refuses offload when weights exceed the budget (paged MoE path)', () => {
        expect(gpuOffloadFits(13.2, 16)).toBe(false);  // 13.2 GB 35B-A3B on 16 GB → CPU + mmap
        expect(gpuOffloadFits(19.0, 24)).toBe(false);
    });

    it('boundary sits at 70% of total RAM', () => {
        expect(gpuOffloadFits(11.2, 16)).toBe(true);
        expect(gpuOffloadFits(11.3, 16)).toBe(false);
    });
});

describe('modelPath', () => {
    it('resolves known model IDs', () => {
        const p = modelPath('llama32-1b');
        expect(p).toContain('llama-3.2-1b-instruct');
        expect(p).toContain('.gguf');
    });

    it('throws for unknown model IDs', () => {
        expect(() => modelPath('nonexistent-model')).toThrow('Unknown model id');
    });
});

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

    it('recommends 3B from 3GB up to under 4GB', () => {
        expect(getRecommendedModelIdForTotalRam(3)).toBe('llama32-3b');
        expect(getRecommendedModelIdForTotalRam(3.99)).toBe('llama32-3b');
    });

    it('recommends Qwen3 4B from 4GB up to under 10GB', () => {
        expect(getRecommendedModelIdForTotalRam(4)).toBe('qwen3-4b');
        expect(getRecommendedModelIdForTotalRam(8)).toBe('qwen3-4b');
        expect(getRecommendedModelIdForTotalRam(9.99)).toBe('qwen3-4b');
    });

    it('recommends Qwen3 14B at 10GB and above', () => {
        expect(getRecommendedModelIdForTotalRam(10)).toBe('qwen3-14b');
        expect(getRecommendedModelIdForTotalRam(18)).toBe('qwen3-14b');
        expect(getRecommendedModelIdForTotalRam(128)).toBe('qwen3-14b');
    });
});

describe('limit constants', () => {
    it('ALLOWED_CONTEXT_SIZES are powers of two or multiples thereof', () => {
        for (const size of ALLOWED_CONTEXT_SIZES) {
            expect(size).toBeGreaterThan(0);
            expect(size % 256).toBe(0);
        }
    });

    it('limits are sensible positive numbers', () => {
        expect(MAX_GOAL_LENGTH).toBeGreaterThan(100);
        expect(MAX_CHAT_LENGTH).toBeGreaterThan(MAX_GOAL_LENGTH);
        expect(MAX_ATTACHMENTS).toBeGreaterThan(0);
        expect(MAX_ATTACHMENT_SIZE).toBeGreaterThan(0);
        expect(MAX_SESSIONS).toBeGreaterThan(10);
        expect(MAX_MESSAGES_PER_SESSION).toBeGreaterThan(10);
    });
});
