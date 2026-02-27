/**
 * Crypto-safe ID generation — ported from off-grid-mobile.
 * Uses Node's native crypto.randomUUID when available,
 * falls back to crypto.getRandomValues, then to a deterministic seed.
 */
import { randomUUID } from 'crypto';

export function generateId(): string {
    return randomUUID();
}

/** Short ID for log correlation (e.g. "1709146823-7a3b") */
export function generateShortId(): string {
    const array = new Uint32Array(1);
    globalThis.crypto.getRandomValues(array);
    return `${Date.now().toString(36)}-${array[0].toString(36).slice(0, 4)}`;
}
