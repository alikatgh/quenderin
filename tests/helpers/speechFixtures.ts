import { createHash } from 'node:crypto';
import { catalog, modelFile } from '@handy-computer/models';
import type { HandySpeechModel } from '../../src/services/speech/types.js';
import type { SpeechDownloadFileSystem, SpeechDownloadHttpResponse } from '../../src/services/speech/downloadManager.js';

export const fixtureBytes = Buffer.from('GGUF synthetic speech fixture');
export const fixtureModel = (overrides: Partial<HandySpeechModel> = {}): HandySpeechModel => {
    const model = catalog.getModel('parakeet-unified-en-0.6b')!;
    return {
        ...model,
        files: { [model.quant]: { ...modelFile(model), size: fixtureBytes.length, sha256: createHash('sha256').update(fixtureBytes).digest('hex') } },
        ...overrides,
    };
};

export function wavFixture() {
    const wav = Buffer.alloc(50);
    wav.write('RIFF', 0);
    wav.writeUInt32LE(wav.length - 8, 4);
    wav.write('WAVEfmt ', 8);
    wav.writeUInt32LE(16, 16);
    wav.writeUInt16LE(1, 20);
    wav.writeUInt16LE(1, 22);
    wav.writeUInt32LE(16000, 24);
    wav.writeUInt32LE(32000, 28);
    wav.writeUInt16LE(2, 32);
    wav.writeUInt16LE(16, 34);
    wav.write('data', 36);
    wav.writeUInt32LE(wav.length - 44, 40);
    wav.writeInt16LE(128, 44);
    return wav;
}

export function httpFixture(status: number, bytes: Uint8Array | null, headers: Record<string, string> = {}): SpeechDownloadHttpResponse {
    return {
        status, ok: status >= 200 && status < 300, headers: new Headers(headers),
        body: bytes && (async function* () { yield bytes; })(),
    };
}

export function speechFsFixture() {
    const files = new Map<string, { bytes: Buffer; identity: string }>();
    let generation = 0;
    const put = (file: string, bytes: Uint8Array) => files.set(file, { bytes: Buffer.from(bytes), identity: `0:${++generation}:0:0` });
    const fs: SpeechDownloadFileSystem = {
        stat: async file => {
            const entry = files.get(file);
            return entry ? { size: entry.bytes.length, identity: entry.identity } : null;
        },
        mkdir: async () => {},
        open: async (file, flag) => {
            if (flag === 'w') put(file, Buffer.alloc(0));
            return {
                write: async bytes => { put(file, Buffer.concat([files.get(file)!.bytes, bytes])); },
                close: async () => {},
            };
        },
        rename: async (from, to) => { files.set(to, files.get(from)!); files.delete(from); },
        unlink: async file => { files.delete(file); },
        async *createReadStream(file, signal) {
            signal?.throwIfAborted();
            yield files.get(file)!.bytes;
        },
    };
    return { fs, files, put };
}
