import { MODEL_CATALOG } from './constants.js';

/** Version of the canonical manifest schema. Bump on a breaking field change. */
export const MANIFEST_VERSION = 1;

/**
 * The canonical, language-neutral model manifest — the single source of truth that iOS
 * (`ModelManifest`) and Android decode. `shared/model-catalog.json` is this object,
 * serialized. The desktop catalog is authoritative; regenerate the JSON with
 * `npm run gen:catalog` and enforce cross-platform parity with
 * `npm run check:catalog-parity`.
 */
export function buildModelManifest() {
  return { version: MANIFEST_VERSION, models: MODEL_CATALOG };
}

/** Pretty, trailing-newline JSON — byte-compatible with `scripts/export_catalog.py`. */
export function modelManifestJSON(): string {
  return `${JSON.stringify(buildModelManifest(), null, 2)}\n`;
}
