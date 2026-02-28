import { describe, expect, it } from 'vitest';
import { getRecommendedModelIdForTotalRam } from '../src/constants.js';

describe('getRecommendedModelIdForTotalRam', () => {
    it('recommends 1B below 3GB', () => {
        expect(getRecommendedModelIdForTotalRam(1)).toBe('llama32-1b');
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
});
