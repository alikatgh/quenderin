import fs from 'node:fs';
import path from 'node:path';
import { verifyModelIntegrity } from './modelIntegrity.js';
import { readGgufModelIdentity } from './ggufModelIdentity.js';
import { generateLocalTokens } from './localTokenGeneration.js';
import { getVerifiedSpecialistRuntime } from './prismRuntime.js';
import { availableMemBytes } from '../utils/memory.js';
import { step5Messages, type Step5Message } from './step5.js';
import { nativeWorkloads } from './nativeWorkloads.js';

export const GRANITE_SOURCE_REVISION = '0d1625d16df2d54cafb6bc5cb0650aec043f77d6';
export const GRANITE_CONVERTER_PATCH_SHA256 = '301fbf51eb833e8481b4f516b28a23cd374f25db88c3e6e8af8277ecad826248';
export const GRANITE_MIN_MEMORY_BYTES = 32 * 1024 ** 3;
export function granitePrompt(messages: readonly Step5Message[]): string {
    const escape = (text: string) => text.replaceAll('<|', '< |');
    return messages.map(message => `<|start_of_role|>${message.role}<|end_of_role|>${escape(message.content)}<|end_of_text|>\n`).join('')
        + '<|start_of_role|>assistant<|end_of_role|>';
}
export class GraniteArtifactProof {
    private constructor(readonly file: string, readonly bytes: number, readonly sha256: string, private readonly identity: fs.BigIntStats) {}
    static async verify(file: string, signal: AbortSignal): Promise<GraniteArtifactProof> {
        signal.throwIfAborted();
        if (path.extname(file).toLowerCase() !== '.gguf') throw new Error('Choose a converted Granite GGUF.');
        const metadata = file + '.quenderin.json';
        const stat = await fs.promises.lstat(metadata, { bigint: true });
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 2n || stat.size > 64n * 1024n) throw new Error('Choose a converted Granite GGUF with its adjacent .quenderin.json provenance record.');
        const same = (current: fs.BigIntStats) => current.isFile() && !current.isSymbolicLink() && stat.dev === current.dev && stat.ino === current.ino
            && stat.size === current.size && stat.mtimeNs === current.mtimeNs && stat.ctimeNs === current.ctimeNs;
        const descriptor = await fs.promises.open(metadata, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
        let receipt: any;
        try {
            if (!same(await descriptor.stat({ bigint: true }))) throw new Error('The Granite provenance record changed.');
            const bytes = Buffer.alloc(Number(stat.size)); let offset = 0;
            while (offset < bytes.length) {
                signal.throwIfAborted();
                const read = await descriptor.read(bytes, offset, bytes.length - offset, offset);
                if (!read.bytesRead) throw new Error('The Granite provenance record is incomplete.');
                offset += read.bytesRead;
            }
            if (!same(await descriptor.stat({ bigint: true })) || !same(await fs.promises.lstat(metadata, { bigint: true }))) throw new Error('The Granite provenance record changed.');
            receipt = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
        } finally { await descriptor.close(); }
        if (receipt.version !== 1 || receipt.source?.repository !== 'ibm-granite/granite-switch-4.1-8b' || receipt.source?.revision !== GRANITE_SOURCE_REVISION || receipt.source?.weightLayers !== 40 ||
            receipt.runtime?.graniteConverterPatchId !== 'granite41-official-converter-v1' || receipt.runtime?.graniteConverterPatchSha256 !== GRANITE_CONVERTER_PATCH_SHA256 || !['f16', 'bf16', 'q8_0'].includes(receipt.outtype) ||
            !Number.isSafeInteger(receipt.bytes) || receipt.bytes < 1024 || receipt.bytes > 32 * 1024 ** 3 || !/^[0-9a-f]{64}$/u.test(receipt.sha256 ?? '')) {
            throw new Error('This file is not a recorded conversion of the pinned Granite Switch 4.1 8B release. Run scripts/convert_granite41.py first.');
        }
        const identity = await fs.promises.lstat(file, { bigint: true });
        if (!identity.isFile() || identity.isSymbolicLink() || identity.size !== BigInt(receipt.bytes)) throw new Error('The complete converted Granite GGUF is missing.');
        await verifyModelIntegrity(file, receipt.sha256, receipt.bytes, signal);
        const actual = await readGgufModelIdentity(file);
        if (actual.architecture !== 'graniteswitch' || (actual.splitCount ?? 1) !== 1 || actual.graniteLayers !== 40 || actual.graniteEmbedding !== 4096) {
            throw new Error('The selected GGUF is not the complete Granite Switch 4.1 8B architecture.');
        }
        const proof = new GraniteArtifactProof(file, receipt.bytes, receipt.sha256, identity);
        await proof.assertCurrent(); return proof;
    }
    async assertCurrent(): Promise<void> {
        const current = await fs.promises.lstat(this.file, { bigint: true }), before = this.identity;
        if (!current.isFile() || current.isSymbolicLink() || before.dev !== current.dev || before.ino !== current.ino || before.size !== current.size || before.mtimeNs !== current.mtimeNs || before.ctimeNs !== current.ctimeNs) throw new Error('The converted Granite file changed. Select and verify it again.');
    }
}

/** General text chat only. Decision/guardian controls and speech require their own explicit workflows. */
export class GraniteChatService {
    private running = false;
    private resources(): void { if (availableMemBytes() < GRANITE_MIN_MEMORY_BYTES) throw new Error('Granite Switch 4.1 requires at least 32 GiB of available app memory.'); }
    async answer(file: string, rawMessages: unknown, parent: AbortSignal): Promise<{ text: string }> {
        return nativeWorkloads.exclusive('Granite Switch', parent, lease => this.answerWithLease(file, rawMessages, lease.signal));
    }
    private async answerWithLease(file: string, rawMessages: unknown, parent: AbortSignal): Promise<{ text: string }> {
        const messages = step5Messages(rawMessages); this.resources();
        if (this.running) throw new Error('A Granite request is already running.'); this.running = true;
        const signal = AbortSignal.any([parent, AbortSignal.timeout(5 * 60_000)]);
        let model: any, context: any;
        try {
            const proof = await GraniteArtifactProof.verify(path.resolve(file), signal);
            const { runtime, bindings } = await getVerifiedSpecialistRuntime();
            if (runtime._bindings?.getQuenderinWeeklyTextRuntimeABI?.() !== 1) throw new Error('This build requires the verified Prism text runtime for Granite Switch.');
            this.resources();
            if (availableMemBytes() < Math.ceil(proof.bytes * 1.3) + 512 * 1024 ** 2) throw new Error('Insufficient current memory for the complete converted Granite model and context.');
            signal.throwIfAborted(); await proof.assertCurrent();
            model = await runtime.loadModel({ modelPath: proof.file, gpuLayers: 0, loadSignal: signal });
            context = await model.createContext({ contextSize: 8192, batchSize: 512, threads: { ideal: 4, max: 8 }, createSignal: signal });
            const prompt = bindings.LlamaText(new bindings.SpecialTokensText(granitePrompt(messages)));
            const tokens = prompt.tokenize(model.tokenizer);
            if (tokens.length + 512 > context.contextSize) throw new Error('This conversation is full. Start a new Granite conversation.');
            let output = '';
            await generateLocalTokens(context.getSequence(), tokens, { maxTokens: 512, temperature: 0.7, signal }, piece => {
                output += piece;
                if (Buffer.byteLength(output) > 256 * 1024) throw new Error('Granite output exceeded its response limit.');
                // Full result is buffered; even split control tokens never reach a renderer.
                return !output.includes('<|');
            });
            output = output.split('<|', 1)[0].trim();
            if (!output || /<\/?think|<tool_call/iu.test(output)) throw new Error('Granite did not return a final text answer.');
            signal.throwIfAborted(); await proof.assertCurrent(); return { text: output };
        } finally {
            try { await context?.dispose(); } finally {
                try { await model?.dispose(); } finally {
                    this.running = false;
                }
            }
        }
    }
}
