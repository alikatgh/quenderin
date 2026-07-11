import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import crypto from 'crypto';
import {
    hasGGUFMagic,
    sha256File,
    verifyModelIntegrity,
    ModelIntegrityError,
    GGUF_MAGIC,
} from '../src/services/modelIntegrity.js';

// Guards audit finding C3: a tampered / truncated / wrong-mirror download must be rejected
// before it ever reaches node-llama-cpp's GGUF parser.
describe('modelIntegrity', () => {
    let dir: string;
    let ggufPath: string;     // valid: GGUF magic + body
    let notGgufPath: string;  // an HTML error page masquerading as a download
    let ggufSha: string;

    beforeAll(() => {
        dir = fs.mkdtempSync(path.join(os.tmpdir(), 'quenderin-integrity-'));
        const body = Buffer.concat([GGUF_MAGIC, Buffer.from('fake gguf payload for testing')]);
        ggufPath = path.join(dir, 'good.gguf');
        fs.writeFileSync(ggufPath, body);
        ggufSha = crypto.createHash('sha256').update(body).digest('hex');

        notGgufPath = path.join(dir, 'oops.html');
        fs.writeFileSync(notGgufPath, '<!doctype html><title>404 Not Found</title>');
    });

    afterAll(() => {
        fs.rmSync(dir, { recursive: true, force: true });
    });

    it('detects the GGUF magic header', () => {
        expect(hasGGUFMagic(GGUF_MAGIC)).toBe(true);
        expect(hasGGUFMagic(Buffer.from('GGUF and then some'))).toBe(true);
        expect(hasGGUFMagic(Buffer.from('<htm'))).toBe(false);
        expect(hasGGUFMagic(Buffer.from('GG'))).toBe(false); // too short
    });

    it('computes a streaming SHA-256 that matches crypto', async () => {
        await expect(sha256File(ggufPath)).resolves.toBe(ggufSha);
    });

    it('passes a valid GGUF with the correct checksum', async () => {
        await expect(verifyModelIntegrity(ggufPath, ggufSha)).resolves.toBeUndefined();
    });

    it('passes magic-only when no checksum is pinned', async () => {
        await expect(verifyModelIntegrity(ggufPath, undefined)).resolves.toBeUndefined();
        await expect(verifyModelIntegrity(ggufPath, null)).resolves.toBeUndefined();
    });

    it('rejects a non-GGUF file (HTML error page, truncation, etc.)', async () => {
        await expect(verifyModelIntegrity(notGgufPath)).rejects.toBeInstanceOf(ModelIntegrityError);
    });

    it('rejects a GGUF whose checksum does not match (tamper / corruption)', async () => {
        await expect(verifyModelIntegrity(ggufPath, 'f'.repeat(64))).rejects.toBeInstanceOf(ModelIntegrityError);
    });

    it('r-uc #5: rejects a header-valid but size-mismatched (truncated) file when no sha is pinned', async () => {
        const actualSize = fs.statSync(ggufPath).size;
        // A truncation that keeps the GGUF magic passes magic+no-sha; the size gate is the only thing
        // that catches it. Expected total larger than what's on disk → reject.
        await expect(verifyModelIntegrity(ggufPath, undefined, actualSize + 5_000_000)).rejects.toBeInstanceOf(ModelIntegrityError);
        // Exact size (or unknown/0) passes.
        await expect(verifyModelIntegrity(ggufPath, undefined, actualSize)).resolves.toBeUndefined();
        await expect(verifyModelIntegrity(ggufPath, undefined, 0)).resolves.toBeUndefined();
    });
});
