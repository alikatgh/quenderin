import { describe, expect, it } from 'vitest';
import {
    getRecommendedModelIdForTotalRam,
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
            expect(m.quantization).toMatch(/^Q\d/);
        }
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
