import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { availableMemBytes } from '../utils/memory.js';
import { readGgufModelIdentity } from './ggufModelIdentity.js';
import type { HyMemoryInstallationPort } from './hyMemory.js';

export const HY_MEMORY_MANIFEST_SHA256 = '3cad9b1d0a47d22676c5fb60dfb7b668668f12c2e34d628392350c676f59b830';
export const HY_MEMORY_BYTES = 18_236_702_240;
export const HY_MEMORY_MIN_MEMORY = 32 * 1024 ** 3;
export const HY_MEMORY_FILENAME = 'Hy-Memory-30B-A3B-Q4_K_M.gguf';
export const HY_MEMORY_SHA256 = '6eea28e22b33661d5d0a464d6fe91762794ceb13c2f5093d8a78d5f4ff3e228b';
const DOWNLOAD_URL = `https://huggingface.co/rapatsky/Hy-Memory-30B-A3B-GGUF/resolve/ac7974ba17f696b57c3c75229d127494b371f46f/${HY_MEMORY_FILENAME}`;
const proofs = new WeakSet<HyMemoryArtifactProof>();
const cancelled = (signal: AbortSignal) => { if (signal.aborted) throw new Error('Hy-Memory operation cancelled.'); };
function same(a: fs.BigIntStats, b: fs.BigIntStats): boolean { return a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs; }

/** An in-process verified capability, never accepted as a renderer-supplied JSON object. */
export class HyMemoryArtifactProof {
    readonly manifestSha256 = HY_MEMORY_MANIFEST_SHA256;
    readonly sha256 = HY_MEMORY_SHA256;
    readonly architecture = 'hy_v3';
    readonly bytes = HY_MEMORY_BYTES;
    private constructor(readonly filePath: string, private readonly identity: fs.BigIntStats) { proofs.add(this); Object.freeze(this); }
    async assertCurrent(): Promise<void> {
        const current = await fs.promises.lstat(this.filePath, { bigint: true });
        if (!proofs.has(this) || !current.isFile() || current.isSymbolicLink() || !same(this.identity, current)) throw new Error('The verified Hy-Memory artifact changed. Verify it again.');
    }
    static async verify(filePath: string, signal: AbortSignal): Promise<HyMemoryArtifactProof> {
        const before = await fs.promises.lstat(filePath, { bigint: true });
        if (!before.isFile() || before.isSymbolicLink() || before.size !== BigInt(HY_MEMORY_BYTES)) throw new Error('Hy-Memory requires the complete pinned 18,236,702,240-byte GGUF.');
        const file = await fs.promises.open(filePath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
        try {
            if (!same(before, await file.stat({ bigint: true }))) throw new Error('Hy-Memory file changed.');
            const hash = crypto.createHash('sha256'); let size = 0;
            for await (const chunk of file.createReadStream({ highWaterMark: 1024 * 1024, autoClose: false, signal })) { cancelled(signal); size += chunk.length; if (size > HY_MEMORY_BYTES) throw new Error('Hy-Memory file grew during verification.'); hash.update(chunk); }
            if (size !== HY_MEMORY_BYTES || hash.digest('hex') !== HY_MEMORY_SHA256 || !same(before, await file.stat({ bigint: true }))) throw new Error('Hy-Memory checksum or file identity mismatch.');
            if ((await readGgufModelIdentity(filePath)).architecture !== 'hy_v3' || !same(before, await fs.promises.lstat(filePath, { bigint: true }))) throw new Error('The specialist GGUF must have actual hy_v3 architecture.');
            cancelled(signal); return new HyMemoryArtifactProof(filePath, before);
        } finally { await file.close(); }
    }
}

export class HyMemoryInstaller implements HyMemoryInstallationPort {
    readonly filePath: string;
    constructor(private readonly directory = path.join(os.homedir(), '.quenderin', 'specialists', 'hy-memory'), private readonly memory = availableMemBytes,
        private readonly totalMemory = os.totalmem) {
        this.filePath = path.join(directory, HY_MEMORY_FILENAME);
        const here = path.dirname(fileURLToPath(import.meta.url));
        const manifestPath = [path.resolve(here, '../../shared/hy-memory-artifacts.json'), path.resolve(here, '../../../shared/hy-memory-artifacts.json')].find(candidate => fs.existsSync(candidate));
        if (!manifestPath) throw new Error('This build has no pinned Hy-Memory manifest.');
        const manifest = fs.readFileSync(manifestPath);
        if (crypto.createHash('sha256').update(manifest).digest('hex') !== HY_MEMORY_MANIFEST_SHA256) throw new Error('Hy-Memory manifest provenance mismatch.');
    }
    async status() {
        const file = await fs.promises.lstat(this.filePath).catch(() => null);
        return { installed: !!file?.isFile() && !file.isSymbolicLink() && file.size === HY_MEMORY_BYTES, availableMemoryBytes: this.memory(), totalMemoryBytes: this.totalMemory(), requiredMemoryBytes: HY_MEMORY_MIN_MEMORY, downloadBytes: HY_MEMORY_BYTES };
    }
    private resources(): void { const available = this.memory(); if (!Number.isFinite(available) || available < HY_MEMORY_MIN_MEMORY) throw new Error('Hy-Memory requires at least 32 GiB of available app memory for the complete specialist.'); }
    async verify(signal: AbortSignal): Promise<HyMemoryArtifactProof> { this.resources(); return HyMemoryArtifactProof.verify(this.filePath, signal); }
    async install(signal: AbortSignal, progress: (fraction: number) => void): Promise<HyMemoryArtifactProof> {
        if (this.totalMemory() < HY_MEMORY_MIN_MEMORY) throw new Error('Hy-Memory requires a device with at least 32 GiB of memory.');
        cancelled(signal);
        await fs.promises.mkdir(this.directory, { recursive: true, mode: 0o700 });
        if ((await fs.promises.realpath(this.directory)) !== path.resolve(this.directory)) throw new Error('Specialist installation folder must not contain symlinks.');
        const existing = await fs.promises.lstat(this.filePath).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
        if (existing) return HyMemoryArtifactProof.verify(this.filePath, signal);
        const disk = await fs.promises.statfs(this.directory, { bigint: true });
        if (disk.bavail * disk.bsize < BigInt(HY_MEMORY_BYTES + 64 * 1024 ** 2)) throw new Error('Insufficient disk space for the complete Hy-Memory specialist and staging reserve.');
        const staging = path.join(this.directory, `.${crypto.randomUUID()}.partial`);
        const file = await fs.promises.open(staging, 'wx', 0o600);
        try {
            let url = new URL(DOWNLOAD_URL), response: Response | undefined;
            for (let redirect = 0; redirect <= 8; redirect++) {
                if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Refusing an unsafe specialist download redirect.');
                const next = await fetch(url, { signal, redirect: 'manual', credentials: 'omit' });
                if ([301, 302, 303, 307, 308].includes(next.status)) {
                    const location = next.headers.get('location'); await next.body?.cancel();
                    if (!location || location.length > 8192) throw new Error('Invalid specialist download redirect.'); url = new URL(location, url); continue;
                }
                response = next; break;
            }
            if (!response) throw new Error('Too many specialist download redirects.');
            if (!response.ok || !response.url.startsWith('https://') || !response.body) throw new Error('Unable to download the pinned public Hy-Memory artifact.');
            const length = response.headers.get('content-length');
            if (length !== null && BigInt(length) !== BigInt(HY_MEMORY_BYTES)) throw new Error('Server returned the wrong Hy-Memory artifact size.');
            const reader = response.body.getReader(); let bytes = 0, reported = 0;
            try {
                while (true) {
                    cancelled(signal); const next = await reader.read(); if (next.done) break;
                    if (next.value.byteLength > 8 * 1024 ** 2 || bytes + next.value.byteLength > HY_MEMORY_BYTES) throw new Error('Hy-Memory download exceeded its pinned size.');
                    let offset = 0;
                    while (offset < next.value.byteLength) {
                        const written = await file.write(next.value, offset, next.value.byteLength - offset);
                        if (!written.bytesWritten) throw new Error('Unable to write the specialist download.'); offset += written.bytesWritten;
                    }
                    bytes += next.value.byteLength;
                    const fraction = bytes / HY_MEMORY_BYTES; if (fraction - reported >= 0.002) { reported = fraction; progress(fraction); }
                }
            } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
            if (bytes !== HY_MEMORY_BYTES) throw new Error('Hy-Memory download was incomplete.');
            await file.sync(); await file.close();
            const proof = await HyMemoryArtifactProof.verify(staging, signal); await proof.assertCurrent(); cancelled(signal);
            await fs.promises.link(staging, this.filePath);
            // Removing the temporary hard-link changes ctime. Seal the published identity only
            // after that cleanup, so the returned proof is current when the caller receives it.
            await fs.promises.unlink(staging);
            const installed = await HyMemoryArtifactProof.verify(this.filePath, signal);
            progress(1); return installed;
        } finally { await file.close().catch(() => {}); await fs.promises.unlink(staging).catch(() => {}); }
    }
}
