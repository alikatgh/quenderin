import fs from 'fs';
import crypto from 'crypto';

/**
 * Post-download integrity verification for GGUF model files (audit finding C3).
 *
 * The downloader streams multi-GB files from catalog-pinned HTTPS URLs straight to disk,
 * then hands them to node-llama-cpp's GGUF parser (which has memory-corruption→RCE CVEs).
 * A TLS-MITM, a poisoned mirror, or a silently-truncated transfer could substitute or
 * corrupt those bytes. This module is the gate between "bytes on disk" and "parsed":
 *   1. the file MUST start with the GGUF magic header, and
 *   2. when the catalog pins a SHA-256, the whole-file digest MUST match it.
 */

/** GGUF files begin with the 4-byte magic "GGUF" (0x47 0x47 0x55 0x46). */
export const GGUF_MAGIC = Buffer.from([0x47, 0x47, 0x55, 0x46]);

export class ModelIntegrityError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'ModelIntegrityError';
    }
}

/** True iff the buffer's first 4 bytes are the GGUF magic header. */
export function hasGGUFMagic(head: Buffer): boolean {
    return head.length >= 4 && head.subarray(0, 4).equals(GGUF_MAGIC);
}

/** Read the first `n` bytes of a file without loading the whole thing into memory. */
async function readHead(filePath: string, n: number): Promise<Buffer> {
    const fh = await fs.promises.open(filePath, 'r');
    try {
        const buf = Buffer.alloc(n);
        const { bytesRead } = await fh.read(buf, 0, n, 0);
        return buf.subarray(0, bytesRead);
    } finally {
        await fh.close();
    }
}

/** Stream the file through SHA-256 (constant memory) → lowercase hex digest. */
export function sha256File(filePath: string): Promise<string> {
    return new Promise((resolve, reject) => {
        const hash = crypto.createHash('sha256');
        const stream = fs.createReadStream(filePath);
        stream.on('error', reject);
        stream.on('data', (chunk) => hash.update(chunk));
        stream.on('end', () => resolve(hash.digest('hex')));
    });
}

/**
 * Verify a freshly-downloaded model file before it is handed to the GGUF parser.
 * Throws {@link ModelIntegrityError} on any mismatch; the caller should delete the file
 * so a retry re-downloads cleanly.
 *
 * Layers: (1) GGUF magic header; (2) exact byte size, when `expectedBytes` is known; (3) full
 * SHA-256, when the catalog pins one. WITHOUT a sha AND without a size, a truncation that keeps
 * the 4-byte header is UNDETECTABLE here (bug hunt r-uc #5 — the old "rejects truncated files"
 * claim was false for exactly that case), so a caller that knows the expected total MUST pass it.
 */
export async function verifyModelIntegrity(filePath: string, expectedSha256?: string | null, expectedBytes?: number): Promise<void> {
    const head = await readHead(filePath, 4);
    if (!hasGGUFMagic(head)) {
        throw new ModelIntegrityError(
            `Downloaded file is not a valid GGUF model (bad magic: 0x${head.toString('hex') || '<empty>'}). ` +
            `The download was likely corrupted, truncated, or intercepted.`,
        );
    }
    if (expectedBytes !== undefined && expectedBytes > 0) {
        const { size } = await fs.promises.stat(filePath);
        if (size !== expectedBytes) {
            throw new ModelIntegrityError(
                `Model size mismatch — expected ${expectedBytes} bytes, got ${size}. ` +
                `The download is incomplete or truncated; refusing to load it.`,
            );
        }
    }
    if (expectedSha256) {
        const actual = await sha256File(filePath);
        if (actual.toLowerCase() !== expectedSha256.toLowerCase()) {
            throw new ModelIntegrityError(
                `Model checksum mismatch — expected SHA-256 ${expectedSha256}, got ${actual}. ` +
                `The file may have been tampered with or corrupted in transit; refusing to load it.`,
            );
        }
    }
}
