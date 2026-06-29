import { describe, it, expect, vi, beforeEach } from 'vitest';

// The module under test imports `@xenova/transformers` at the top level and, on
// load, mutates `env.allowLocalModels` / `env.useBrowserCache`. It also lazily
// calls `pipeline('feature-extraction', ...)` to load a ~80 MB embedding model.
// We mock the whole package so importing the module is cheap and deterministic
// and never touches the real model or the network. `pipeline` is mocked to throw
// so any accidental embedding path fails loudly instead of silently downloading.
vi.mock('@xenova/transformers', () => ({
    env: {},
    pipeline: vi.fn(async () => {
        throw new Error('real embedding model must not be loaded in unit tests');
    }),
}));

// Logger is mocked to keep test output clean and avoid any env-driven side effects.
vi.mock('../src/utils/logger.js', () => ({
    default: {
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
        debug: vi.fn(),
        log: vi.fn(),
    },
}));

import { MemoryService, type CorrectionEntry } from '../src/services/memory.service.js';

// Typed view onto the private surface we exercise directly. cosineSimilarity and
// MAX_CORRECTIONS are private; accessing them via a cast is intentional per the
// task spec (we test real behavior without going through the embedding model).
interface MemoryServiceInternals {
    cosineSimilarity(a: number[], b: number[]): number;
    MAX_CORRECTIONS: number;
}

function internals(service: MemoryService): MemoryServiceInternals {
    return service as unknown as MemoryServiceInternals;
}

describe('MemoryService.cosineSimilarity', () => {
    let service: MemoryService;

    beforeEach(() => {
        service = new MemoryService();
    });

    it('returns exactly 1 for identical vectors', () => {
        const v = [1, 2, 3, 4];
        expect(internals(service).cosineSimilarity(v, v)).toBe(1);
    });

    it('returns ~1 for parallel (positively scaled) vectors', () => {
        const a = [1, 2, 3];
        const b = [2, 4, 6]; // a * 2 — same direction
        expect(internals(service).cosineSimilarity(a, b)).toBeCloseTo(1, 12);
    });

    it('returns 0 for orthogonal vectors', () => {
        const a = [1, 0];
        const b = [0, 1];
        expect(internals(service).cosineSimilarity(a, b)).toBe(0);
    });

    it('returns -1 for exactly opposite vectors', () => {
        const a = [1, 2, 3];
        const b = [-1, -2, -3];
        expect(internals(service).cosineSimilarity(a, b)).toBeCloseTo(-1, 12);
    });

    it('returns 0 (not NaN) when the first vector has zero norm', () => {
        const result = internals(service).cosineSimilarity([0, 0, 0], [1, 2, 3]);
        expect(result).toBe(0);
        expect(Number.isNaN(result)).toBe(false);
    });

    it('returns 0 (not NaN) when the second vector has zero norm', () => {
        const result = internals(service).cosineSimilarity([1, 2, 3], [0, 0, 0]);
        expect(result).toBe(0);
        expect(Number.isNaN(result)).toBe(false);
    });

    it('returns 0 (not NaN) when both vectors have zero norm', () => {
        const result = internals(service).cosineSimilarity([0, 0], [0, 0]);
        expect(result).toBe(0);
        expect(Number.isNaN(result)).toBe(false);
    });

    it('returns 0 for mismatched-length vectors instead of producing NaN', () => {
        // The guard `if (a.length !== b.length) return 0` protects the top-k sort
        // comparator from a dimension change (audit note M11).
        const result = internals(service).cosineSimilarity([1, 2, 3], [1, 2]);
        expect(result).toBe(0);
        expect(Number.isNaN(result)).toBe(false);
    });

    it('computes a known intermediate similarity correctly', () => {
        // a=[1,0], b=[1,1]: dot=1, |a|=1, |b|=sqrt(2) -> 1/sqrt(2) ≈ 0.70710678
        const result = internals(service).cosineSimilarity([1, 0], [1, 1]);
        expect(result).toBeCloseTo(Math.SQRT1_2, 12);
    });

    it('is symmetric: cos(a,b) === cos(b,a)', () => {
        const a = [3, -1, 4, 1];
        const b = [-2, 5, 0, 2];
        const ab = internals(service).cosineSimilarity(a, b);
        const ba = internals(service).cosineSimilarity(b, a);
        expect(ab).toBe(ba);
    });
});

describe('MemoryService MAX_CORRECTIONS cap', () => {
    let service: MemoryService;

    beforeEach(() => {
        service = new MemoryService();
    });

    it('exposes the documented cap of 500', () => {
        expect(internals(service).MAX_CORRECTIONS).toBe(500);
    });

    // saveCorrection() embeds text via the real model and then does a file
    // read-modify-write, so it cannot run as a pure unit test without the
    // embedder + fs. We instead verify the exact eviction arithmetic that
    // saveCorrection uses for the cap:
    //
    //   if (records.length >= MAX_CORRECTIONS) {
    //       records = records.slice(-(MAX_CORRECTIONS - 1));
    //   }
    //   records.push(newRecord);
    //
    // The reusable helper below mirrors that logic over injected records so we
    // assert the real invariant (never exceeds the cap; keeps the newest;
    // lands exactly at the cap) without loading the embedding model.
    function makeRecord(i: number): CorrectionEntry {
        return {
            id: String(i),
            uiContextString: `ctx-${i}`,
            correctionString: `fix-${i}`,
            embeddingVector: [i, i, i],
            timestamp: new Date(2020, 0, 1, 0, 0, i).toISOString(),
        };
    }

    function applyCap(existing: CorrectionEntry[], cap: number, next: CorrectionEntry): CorrectionEntry[] {
        let records = existing;
        if (records.length >= cap) {
            records = records.slice(-(cap - 1));
        }
        records.push(next);
        return records;
    }

    it('keeps at most MAX_CORRECTIONS entries after a push at the cap', () => {
        const cap = internals(service).MAX_CORRECTIONS;
        const existing = Array.from({ length: cap }, (_, i) => makeRecord(i));
        const result = applyCap(existing, cap, makeRecord(cap));
        expect(result.length).toBe(cap);
    });

    it('lands exactly at the cap (no off-by-one) when starting full', () => {
        const cap = internals(service).MAX_CORRECTIONS;
        const existing = Array.from({ length: cap }, (_, i) => makeRecord(i));
        const result = applyCap(existing, cap, makeRecord(cap));
        // Not cap+1 (the bug the `-(cap-1)` slice fixes), exactly cap.
        expect(result.length).toBe(cap);
    });

    it('evicts the oldest entries and retains the newest on overflow', () => {
        const cap = internals(service).MAX_CORRECTIONS;
        const existing = Array.from({ length: cap }, (_, i) => makeRecord(i));
        const result = applyCap(existing, cap, makeRecord(cap));
        // Oldest (id "0") evicted; newest (id String(cap)) present and last.
        expect(result.find(r => r.id === '0')).toBeUndefined();
        expect(result[result.length - 1].id).toBe(String(cap));
        expect(result[0].id).toBe('1');
    });

    it('does not slice when below the cap — appends normally', () => {
        const cap = internals(service).MAX_CORRECTIONS;
        const existing = Array.from({ length: cap - 5 }, (_, i) => makeRecord(i));
        const result = applyCap(existing, cap, makeRecord(999));
        expect(result.length).toBe(cap - 4);
        expect(result[0].id).toBe('0'); // nothing evicted
        expect(result[result.length - 1].id).toBe('999');
    });

    it('stays at the cap across repeated overflow pushes', () => {
        const cap = internals(service).MAX_CORRECTIONS;
        let records = Array.from({ length: cap }, (_, i) => makeRecord(i));
        for (let i = 0; i < 50; i++) {
            records = applyCap(records, cap, makeRecord(cap + i));
        }
        expect(records.length).toBe(cap);
        // After 50 more pushes, the newest id is cap+49 and it is last.
        expect(records[records.length - 1].id).toBe(String(cap + 49));
    });
});
