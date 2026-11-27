import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { accuracyGrade, catalog, CURATED_MODELS, modelMatchesLanguage } from '@handy-computer/models';
import { buildModelSummary, engineCompatibility, englishGrade, speedLevel } from '../src/services/speech/grading.js';

describe('Handy desktop grades and speed bands', () => {
    const handySpeedBars = path.join(process.env.HANDY_REF || '/workspace/handy-ref', 'src/components/shared/SpeedBars.tsx');
    const cutoffs = existsSync(handySpeedBars)
        ? JSON.parse(readFileSync(handySpeedBars, 'utf8').match(/SPEED_CUTOFFS = (\[[^\]]+\])/u)![1]) as number[]
        : [2, 3.5, 7.5, 20];

    it.each(CURATED_MODELS.map(model => [model.id, model] as const))('agrees with the Handy package for %s', (_, model) => {
        const grade = catalog.languageAccuracyGrade(model, 'en');
        const wait = catalog.modelWaitSeconds(model, 'accelerated');
        const row = buildModelSummary(catalog, model, '0.4.1', false);
        const unsupported = !modelMatchesLanguage(model, 'en');
        expect(row.englishGrade).toEqual({
            letter: unsupported ? 'none' : grade?.letter ?? 'none',
            label: unsupported ? '—' : grade?.label.replace('-', '−') ?? '?',
        });
        expect(row.waitSeconds).toBe(wait ?? null);
        expect(row.speedLevel).toBe(wait === undefined ? 0 : cutoffs.filter(cutoff => wait < cutoff).length);
        expect(row.engine.compatibility).toBe('supported');
    });

    it('distinguishes unmeasured English and uses the package subgrades', () => {
        const model = catalog.getModel('parakeet-unified-en-0.6b')!;
        expect(englishGrade({ ...catalog, languageAccuracyGrade: () => undefined }, model)).toEqual({ letter: 'none', label: '?' });
        expect(englishGrade(catalog, model)).toEqual({ letter: 'A', label: accuracyGrade(3.99).label.replace('-', '−') });
    });

    it('applies strict wait cutoffs and numeric engine versions', () => {
        expect([undefined, 0, ...cutoffs].map(speedLevel)).toEqual([0, 4, 3, 2, 1, 0]);
        expect(engineCompatibility('0.4.10', '0.4.2')).toBe('needs-newer-engine');
        expect(engineCompatibility('0.4.0', '0.4.1')).toBe('supported');
    });
});
