import { describe, it, expect } from 'vitest';
import { boxToGeometry } from '../src/services/uiParser.service.js';

/**
 * Q-379: boxToGeometry computed width/height as x2-x1 / y2-y1 directly, so inverted bounds (x2<x1 or
 * y2<y1 — RTL layouts, malformed accessibility data) produced a NEGATIVE width/height and a wrong
 * origin. It now normalizes the corners first. The center (tap point) is a midpoint, so it's unchanged.
 */
describe('boxToGeometry (Q-379 inverted-bounds normalization)', () => {
    it('normal bounds: top-left origin, positive dims, midpoint center', () => {
        const g = boxToGeometry(10, 20, 110, 220);
        expect(g.rect).toEqual({ x: 10, y: 20, width: 100, height: 200 });
        expect(g.center).toEqual({ x: 60, y: 120 });
    });

    it('inverted corners never yield negative dims, and give the true top-left + same center', () => {
        const g = boxToGeometry(110, 220, 10, 20);   // corners swapped
        expect(g.rect.width).toBe(100);
        expect(g.rect.height).toBe(200);
        expect(g.rect.x).toBe(10);
        expect(g.rect.y).toBe(20);
        expect(g.center).toEqual({ x: 60, y: 120 });   // identical to the non-inverted case
    });

    it('mixed inversion (x ok, y flipped) is normalized on the flipped axis only', () => {
        const g = boxToGeometry(10, 220, 110, 20);
        expect(g.rect).toEqual({ x: 10, y: 20, width: 100, height: 200 });
    });
});
