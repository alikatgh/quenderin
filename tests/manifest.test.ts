import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { buildModelManifest, MANIFEST_VERSION } from '../src/manifest';

/**
 * The committed `shared/model-catalog.json` is the canonical manifest the mobile clients
 * consume. It must stay in lockstep with the desktop catalog (the source of truth). This
 * is the JS-native half of that guarantee (the cross-language half is
 * `scripts/check_catalog_parity.py`).
 */
describe('canonical model manifest', () => {
  const committed = JSON.parse(
    readFileSync(resolve(process.cwd(), 'shared/model-catalog.json'), 'utf-8'),
  ) as { version: number; models: Array<Record<string, unknown>> };
  const built = buildModelManifest();

  it('has the expected version and model count', () => {
    expect(committed.version).toBe(MANIFEST_VERSION);
    expect(committed.models).toHaveLength(built.models.length);
  });

  it('matches the desktop catalog field-for-field (run `npm run gen:catalog` if this fails)', () => {
    expect(committed.models.map((m) => m.id).sort()).toEqual(built.models.map((m) => m.id).sort());

    const FIELDS = ['label', 'filename', 'ramGb', 'sizeLabel', 'paramsBillions', 'quantization', 'url'] as const;
    for (const cm of committed.models) {
      const bm = built.models.find((m) => m.id === cm.id);
      expect(bm, `model ${cm.id} is in the manifest but not the catalog`).toBeDefined();
      if (!bm) continue;
      const record = bm as unknown as Record<string, unknown>;
      for (const field of FIELDS) {
        expect(record[field], `${cm.id}.${field}`).toEqual(cm[field]);
      }
    }
  });
});
