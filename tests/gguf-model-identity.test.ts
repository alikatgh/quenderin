import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readGgufModelIdentity } from '../src/services/ggufModelIdentity.js';
import { getModelRuntimeCompatibility, PRISM_LLAMA_CPP_REPO, PRISM_LLAMA_CPP_REVISION } from '../src/services/modelRuntime.js';

function uint(value: bigint | number, width: number): Buffer {
    const buffer = Buffer.alloc(width);
    if (width === 8) buffer.writeBigUInt64LE(BigInt(value)); else buffer.writeUIntLE(Number(value), 0, width);
    return buffer;
}
function string(value: string | Buffer): Buffer {
    const data = typeof value === 'string' ? Buffer.from(value) : value;
    return Buffer.concat([uint(data.length, 8), data]);
}
function field(key: string, type: number, value: Buffer): Buffer { return Buffer.concat([string(key), uint(type, 4), value]); }
function gguf(fields: Buffer[], count = fields.length): Buffer {
    return Buffer.concat([Buffer.from('GGUF'), uint(3, 4), uint(0, 8), uint(count, 8), ...fields]);
}
const architecture = (name: string) => field('general.architecture', 8, string(name));
let directory: string;
beforeEach(async () => { directory = await mkdtemp(path.join(os.tmpdir(), 'gguf-identity-test-')); });
afterEach(async () => { vi.restoreAllMocks(); await rm(directory, { recursive: true, force: true }); });
async function fixture(data: Buffer): Promise<string> {
    const file = path.join(directory, 'tiny.gguf'); await writeFile(file, data); return file;
}

describe('bounded GGUF model identity preflight', () => {
    it.each(['llama', 'k2-horizon', 'beam'])('reads %s identity without tensor allocation', async arch => {
        const file = await fixture(gguf([architecture(arch), field('general.name', 8, string('Tiny fixture'))]));
        const identity = await readGgufModelIdentity(file);
        expect(identity).toEqual({ architecture: arch, modelName: 'Tiny fixture' });
        const runtime = { buildType: 'localBuild', llamaCppRelease: { repo: PRISM_LLAMA_CPP_REPO, release: PRISM_LLAMA_CPP_REVISION }, weeklyTextABI: 1 };
        expect(getModelRuntimeCompatibility({ id: 'harmless-alias', ...identity }, runtime).canLoad).toBe(arch !== 'beam');
        if (arch === 'k2-horizon') expect(getModelRuntimeCompatibility(identity).canLoad).toBe(false);
    });

    it('skips unrelated strings and tokenizer arrays instead of decoding or materializing them', async () => {
        const data = gguf([architecture('llama'),
            field('unrelated.payload', 8, string(Buffer.alloc(20_000, 255))),
            field('tokenizer.ggml.tokens', 9, Buffer.concat([uint(8, 4), uint(2, 8), string(Buffer.from([255])), string('token')])),
            field('test.numeric', 9, Buffer.concat([uint(10, 4), uint(2, 8), uint(1, 8), uint(2, 8)])),
            field('general.name', 8, string('Ordinary'))]);
        const file = await fixture(data);
        const allocate = Buffer.alloc.bind(Buffer);
        const allocations = vi.spyOn(Buffer, 'alloc').mockImplementation((size, fill, encoding) => {
            if (size > 8192) throw new Error('Unexpected oversized allocation');
            return allocate(size, fill, encoding);
        });
        expect(await readGgufModelIdentity(file)).toEqual({ architecture: 'llama', modelName: 'Ordinary' });
        expect(allocations.mock.calls.every(([size]) => size <= 4096)).toBe(true);
    });

    it.each([
        gguf([field('general.architecture', 8, uint(1024 ** 3, 8))]),
        gguf([architecture('llama'), field('unknown', 8, uint(1024 ** 3, 8))]),
        gguf([architecture('llama'), field('unknown', 9, Buffer.concat([uint(10, 4), uint(2_000_001, 8)]))]),
        gguf([architecture('llama'), field('unknown', 9, Buffer.concat([uint(12, 4), uint(0xffffffffffffffffn, 8)]))]),
        gguf([architecture('llama'), field('unknown', 9, Buffer.concat([uint(9, 4), uint(0, 8)]))]),
        gguf([architecture('llama'), field('unknown', 10, uint(1, 4))]),
        gguf([field('general.architecture', 8, Buffer.concat([uint(10, 8), Buffer.from('x')]))]),
        gguf([architecture('beam'), architecture('llama')]),
        gguf([architecture('llama'), field('general.name', 8, string('One')), field('general.name', 8, string('Two'))]),
        gguf([], 100_001),
    ])('rejects malicious/truncated tiny metadata before a large allocation (%#)', async data => {
        const file = await fixture(data);
        const allocate = Buffer.alloc.bind(Buffer);
        const allocations = vi.spyOn(Buffer, 'alloc').mockImplementation((size, fill, encoding) => {
            if (size > 8192) throw new Error('Unexpected oversized allocation');
            return allocate(size, fill, encoding);
        });
        await expect(readGgufModelIdentity(file)).rejects.toThrow(/GGUF/);
        expect(allocations.mock.calls.every(([size]) => size <= 4096)).toBe(true);
    });
});
