import { describe, it, expect } from 'vitest';
import { planDownloadWrite, parseContentRangeStart } from '../src/services/modelDownloadPlan.js';

/**
 * The H9 byte-accounting logic governs bytes that reach node-llama-cpp's GGUF parser (RCE CVEs),
 * yet it was only exercised end-to-end. These pin every branch of the restart/resume/discard
 * decision — the exact cases the June H9 fix introduced.
 */
describe('parseContentRangeStart', () => {
    it('reads the start byte of a well-formed header', () => {
        expect(parseContentRangeStart('bytes 500-999/2000')).toBe(500);
        expect(parseContentRangeStart('bytes 0-99/100')).toBe(0);
    });
    it('is case-insensitive and tolerant of extra whitespace', () => {
        expect(parseContentRangeStart('BYTES   1234-5678/9999')).toBe(1234);
    });
    it('returns null for a missing or unparseable header', () => {
        expect(parseContentRangeStart(null)).toBeNull();
        expect(parseContentRangeStart(undefined)).toBeNull();
        expect(parseContentRangeStart('*/2000')).toBeNull();
        expect(parseContentRangeStart('items 1-2')).toBeNull();
    });
});

describe('planDownloadWrite', () => {
    it('fresh download (no partial, 200) → restart from 0, truncate, total = content-length', () => {
        const p = planDownloadWrite({ partialBytes: 0, status: 200, contentRange: null, contentLength: 5000 });
        expect(p).toEqual({ action: 'restart', writeOffset: 0, append: false, totalBytes: 5000 });
    });

    it('H9: had a partial but server sent 200 (ignored our Range) → restart, NOT append', () => {
        // The bug this guards: keeping the stale partial size would make progress exceed 100%
        // and the full body would be appended after the existing bytes, doubling the header.
        const p = planDownloadWrite({ partialBytes: 1_000_000, status: 200, contentRange: null, contentLength: 5_000_000 });
        expect(p.action).toBe('restart');
        expect(p.writeOffset).toBe(0);
        expect(p.append).toBe(false);
        expect(p.totalBytes).toBe(5_000_000);
    });

    it('genuine resume (206, Content-Range start == partial) → append at the offset', () => {
        const p = planDownloadWrite({
            partialBytes: 1_000_000,
            status: 206,
            contentRange: 'bytes 1000000-4999999/5000000',
            contentLength: 4_000_000,
        });
        expect(p.action).toBe('resume');
        expect(p.writeOffset).toBe(1_000_000);
        expect(p.append).toBe(true);
        // total = what we already have + what THIS response body carries
        expect(p.totalBytes).toBe(5_000_000);
    });

    it('H9: 206 with a MISMATCHED Content-Range start → discard (would corrupt the GGUF)', () => {
        const p = planDownloadWrite({
            partialBytes: 1_000_000,
            status: 206,
            contentRange: 'bytes 2000000-4999999/5000000', // server resumed from the wrong place
            contentLength: 3_000_000,
        });
        expect(p.action).toBe('discard');
        expect(p.append).toBe(false);
        expect(p.discardReason).toMatch(/offset mismatch/i);
        expect(p.discardReason).toContain('1000000'); // local partial size surfaced for diagnosis
    });

    it('H9: 206 with NO Content-Range header → discard (can\'t verify the offset)', () => {
        const p = planDownloadWrite({ partialBytes: 500, status: 206, contentRange: null, contentLength: 1500 });
        expect(p.action).toBe('discard');
        expect(p.discardReason).toContain('none');
    });

    it('resume at offset 0 (206 with start 0 and no local partial) is coherent', () => {
        const p = planDownloadWrite({ partialBytes: 0, status: 206, contentRange: 'bytes 0-99/100', contentLength: 100 });
        expect(p.action).toBe('resume');
        expect(p.writeOffset).toBe(0);
        expect(p.totalBytes).toBe(100);
    });

    it('unknown content-length (0) is carried through, not invented', () => {
        const p = planDownloadWrite({ partialBytes: 0, status: 200, contentRange: null, contentLength: 0 });
        expect(p.totalBytes).toBe(0); // progress math downstream guards on totalBytes > 0
    });
});
