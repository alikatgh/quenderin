import { open } from 'node:fs/promises';

export interface GgufModelIdentity { architecture: string; modelName?: string }

/** Metadata only: bounded reads and cursor skips, never tokenizer arrays or tensor payloads. */
export async function readGgufModelIdentity(path: string): Promise<GgufModelIdentity> {
    const file = await open(path, 'r');
    try {
        const size = (await file.stat()).size;
        const limit = Math.min(size, 64 * 1024 * 1024);
        let offset = 0;
        const invalid = () => new Error('Invalid, truncated or oversized GGUF metadata.');
        function checkedSize(count: bigint): number {
            if (count < 0n || count > BigInt(limit - offset)) throw invalid();
            return Number(count);
        }
        async function bytes(count: number): Promise<Buffer> {
            checkedSize(BigInt(count));
            const data = Buffer.alloc(count);
            let filled = 0;
            while (filled < count) {
                const { bytesRead } = await file.read(data, filled, count - filled, offset + filled);
                if (bytesRead === 0) throw invalid();
                filled += bytesRead;
            }
            offset += count;
            return data;
        }
        async function integer(width: number): Promise<bigint> {
            const data = await bytes(width);
            return width === 8 ? data.readBigUInt64LE() : BigInt(data.readUIntLE(0, width));
        }
        async function string(maximum: bigint): Promise<string> {
            const length = await integer(8);
            if (length > maximum) throw invalid();
            return new TextDecoder('utf-8', { fatal: true }).decode(await bytes(checkedSize(length)));
        }
        function skip(count: bigint): void { offset += checkedSize(count); }
        function width(type: bigint): bigint {
            if ([0n, 1n, 7n].includes(type)) return 1n;
            if ([2n, 3n].includes(type)) return 2n;
            if ([4n, 5n, 6n].includes(type)) return 4n;
            if ([10n, 11n, 12n].includes(type)) return 8n;
            throw invalid();
        }
        if ((await bytes(4)).toString('ascii') !== 'GGUF') throw invalid();
        const version = await integer(4);
        if (version !== 2n && version !== 3n) throw invalid();
        await integer(8); // tensor count; no tensor descriptors or weights are read
        const count = await integer(8);
        if (count > 100_000n) throw invalid();
        let architecture: string | undefined;
        let modelName: string | undefined;
        for (let i = 0n; i < count; i++) {
            const key = await string(1024n);
            const type = await integer(4);
            if (key === 'general.architecture' || key === 'general.name') {
                if (type !== 8n) throw invalid();
                if (key === 'general.architecture') {
                    if (architecture !== undefined) throw invalid();
                    architecture = await string(256n);
                } else {
                    if (modelName !== undefined) throw invalid();
                    modelName = await string(4096n);
                }
            } else if (type === 8n) {
                skip(await integer(8));
            } else if (type === 9n) {
                const element = await integer(4);
                const items = await integer(8);
                if (items > 2_000_000n || element === 9n) throw invalid();
                if (element === 8n) {
                    for (let j = 0n; j < items; j++) skip(await integer(8));
                } else skip(items * width(element));
            } else skip(width(type));
        }
        if (!architecture?.trim()) throw invalid();
        return { architecture, modelName };
    } finally {
        await file.close();
    }
}
