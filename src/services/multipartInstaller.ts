import fs from 'node:fs';
import path from 'node:path';
import { verifyModelIntegrity } from './modelIntegrity.js';
import { pinnedMultipartParts, type ModelArtifact, type MultipartDescriptor } from './multipartModels.js';
import { planDownloadWrite } from './modelDownloadPlan.js';

function safePath(directory: string, part: ModelArtifact): string {
    if (!/^[A-Za-z0-9_.-]+\.gguf$/.test(part.filename) || part.filename.startsWith('.')) throw new Error('Unsafe model artifact filename');
    return path.join(directory, part.filename);
}

function validateParts(parts: readonly ModelArtifact[]): void {
    if (!parts.length || parts.length > 64) throw new Error('Invalid artifact set count.');
    const names = new Set<string>(); let total = 0;
    for (const part of parts) {
        safePath('.', part);
        const url = new URL(part.url);
        if (url.protocol !== 'https:' || url.hostname !== 'huggingface.co' || url.username || url.password || url.port || url.hash
            || !/^\/[^/]+\/[^/]+\/resolve\/[0-9a-f]{40}\//.test(url.pathname)
            || !/^[0-9a-f]{64}$/.test(part.sha256) || !Number.isSafeInteger(part.downloadBytes) || part.downloadBytes <= 0
            || names.has(part.filename.toLowerCase())) throw new Error('Invalid immutable artifact set.');
        names.add(part.filename.toLowerCase()); total += part.downloadBytes;
    }
    if (!Number.isSafeInteger(total) || total > 1024 ** 4) throw new Error('Artifact set exceeds the bounded disk budget.');
}

async function reusablePartial(destination: string, part: ModelArtifact): Promise<number> {
    const staging = destination + '.download.part', receipt = destination + '.download.json';
    const partial = await fs.promises.lstat(staging).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    const record = await fs.promises.lstat(receipt).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
    if (!partial) { if (record) throw new Error('Existing download receipt is preserved; remove it explicitly before retrying.'); return 0; }
    if (partial.nlink !== 1) throw new Error('Partial model must be an exclusive ordinary file.');
    const identity = JSON.stringify(part);
    if (!partial.isFile() || partial.isSymbolicLink() || partial.size > part.downloadBytes || !record?.isFile() || record.isSymbolicLink()
        || record.size !== Buffer.byteLength(identity) || await fs.promises.readFile(receipt, 'utf8') !== identity) {
        throw new Error('Unrecognized partial model file is preserved; remove it explicitly before retrying.');
    }
    // Sparse/unallocated bytes must not be credited as space already consumed.
    return Math.min(partial.size, partial.blocks * 512);
}

export async function verifyMultipartModel(model: MultipartDescriptor, firstPath: string, signal?: AbortSignal): Promise<void> {
    const parts = pinnedMultipartParts(model);
    if (!parts || path.basename(firstPath) !== parts[0].filename) throw new Error('A complete pinned multipart model manifest is required.');
    await verifyArtifactSet(parts, path.dirname(firstPath), signal);
}

export async function verifyArtifactSet(parts: readonly ModelArtifact[], directory: string, signal?: AbortSignal): Promise<void> {
    validateParts(parts);
    for (const part of parts) {
        signal?.throwIfAborted();
        const filename = safePath(directory, part);
        const before = await fs.promises.lstat(filename, { bigint: true });
        if (!before.isFile() || before.isSymbolicLink()) throw new Error('Model artifacts must be ordinary files.');
        await verifyModelIntegrity(filename, part.sha256, part.downloadBytes, signal);
        const after = await fs.promises.lstat(filename, { bigint: true });
        if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
            || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) throw new Error('Model artifact changed during verification.');
    }
}

/** Sequential, resumable, immutable shard install. No first-shard-only success event. */
export async function installMultipartModel(model: MultipartDescriptor, directory: string,
    progress: (fraction: number) => void, request: typeof fetch = fetch, signal?: AbortSignal): Promise<void> {
    const parts = pinnedMultipartParts(model);
    if (!parts) throw new Error('A complete pinned multipart model manifest is required.');
    await installArtifactSet(parts, directory, progress, request, signal);
}

/** Trusted built-in manifests only. No renderer-provided URLs or paths are accepted by app routes. */
export async function installArtifactSet(parts: readonly ModelArtifact[], directory: string,
    progress: (fraction: number) => void, request: typeof fetch = fetch, signal?: AbortSignal): Promise<void> {
    validateParts(parts);
    signal?.throwIfAborted();
    await fs.promises.mkdir(directory, { recursive: true });
    if (await fs.promises.realpath(directory) !== path.resolve(directory)) throw new Error('Model artifact folder must not traverse symbolic links.');
    const total = parts.reduce((sum, part) => sum + part.downloadBytes, 0);
    let remaining = total;
    for (const part of parts) {
        signal?.throwIfAborted();
        const destination = safePath(directory, part);
        if (fs.existsSync(destination)) {
            // Existing originals are preserved on failure, never silently replaced.
            await verifyArtifactSet([part], directory, signal);
            remaining -= part.downloadBytes;
        } else remaining -= await reusablePartial(destination, part);
    }
    const disk = await fs.promises.statfs(directory, { bigint: true });
    if (disk.bavail * disk.bsize < BigInt(remaining) + 512n * 1024n * 1024n) throw new Error('Insufficient disk space for the complete model artifact set.');
    let completed = 0;
    for (const part of parts) {
        signal?.throwIfAborted();
        const destination = safePath(directory, part);
        if (fs.existsSync(destination)) { completed += part.downloadBytes; progress(Math.min(0.999, completed / total)); continue; }
        const staging = destination + '.download.part';
        const receipt = destination + '.download.json';
        const identity = JSON.stringify(part);
        if (fs.existsSync(staging)) {
            await reusablePartial(destination, part);
        } else {
            if (fs.existsSync(receipt)) throw new Error('Existing download receipt is preserved; remove it explicitly before retrying.');
            await fs.promises.writeFile(receipt, identity, { flag: 'wx' });
            await fs.promises.writeFile(staging, '', { flag: 'wx' });
        }
        let offset = (await fs.promises.stat(staging)).size;
        if (offset < part.downloadBytes) {
            // One bounded response per shard. A valid partial survives interruption/retry.
            const response = await request(part.url, { headers: offset ? { Range: `bytes=${offset}-` } : {}, signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(30 * 60 * 1000)]) });
            if (!response.ok || !response.body) throw new Error(`Model download failed (${response.status}).`);
            const plan = planDownloadWrite({ partialBytes: offset, status: response.status, contentRange: response.headers.get('content-range'), contentLength: Number(response.headers.get('content-length')) || 0 });
            if (plan.action === 'discard') { await response.body.cancel(); throw new Error('Server returned an inconsistent resume range; partial file preserved.'); }
            offset = plan.writeOffset;
            const before = await fs.promises.lstat(staging, { bigint: true });
            const handle = await fs.promises.open(staging, fs.constants.O_WRONLY | (fs.constants.O_NOFOLLOW ?? 0) | (plan.append ? fs.constants.O_APPEND : 0));
            try {
                const same = (current: fs.BigIntStats) => current.isFile() && current.nlink === 1n && !current.isSymbolicLink() && before.dev === current.dev && before.ino === current.ino && before.size === current.size && before.mtimeNs === current.mtimeNs && before.ctimeNs === current.ctimeNs;
                if (!before.isFile() || before.nlink !== 1n || before.isSymbolicLink() || !same(await handle.stat({ bigint: true })) || !same(await fs.promises.lstat(staging, { bigint: true }))) throw new Error('Partial model changed before transfer.');
                // A server may ignore Range. Truncate only our identified ordinary partial,
                // which also releases the credited space before the replacement transfer.
                if (!plan.append) await handle.truncate(0);
                for await (const chunk of response.body as any) {
                    signal?.throwIfAborted();
                    const bytes = Buffer.from(chunk);
                    if (offset + bytes.length > part.downloadBytes) throw new Error('Model response exceeds the pinned shard size.');
                    let written = 0;
                    while (written < bytes.length) {
                        const result = await handle.write(bytes, written, bytes.length - written, offset + written);
                        if (!result.bytesWritten) throw new Error('Model download write made no progress.');
                        written += result.bytesWritten;
                    }
                    offset += bytes.length;
                    progress(Math.min(0.999, (completed + offset) / total));
                }
                await handle.sync();
            } finally { await handle.close(); }
        }
        await verifyModelIntegrity(staging, part.sha256, part.downloadBytes, signal);
        signal?.throwIfAborted();
        // Exclusive publication avoids replacing an original that appeared during transfer.
        await fs.promises.link(staging, destination);
        await fs.promises.unlink(staging);
        await fs.promises.unlink(receipt);
        completed += part.downloadBytes;
        progress(Math.min(0.999, completed / total));
    }
    await verifyArtifactSet(parts, directory, signal);
    progress(1);
}
