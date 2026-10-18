import { generateLocalTokens } from './localTokenGeneration.js';
import type { HyMemoryInferencePort, HyMemoryInferenceRequest } from './hyMemory.js';
import { HyMemoryArtifactProof, HY_MEMORY_MIN_MEMORY } from './hyMemoryInstaller.js';
import { availableMemBytes } from '../utils/memory.js';
import { getVerifiedSpecialistRuntime, specialistRuntimeUnavailableReason } from './prismRuntime.js';
import { nativeWorkloads, type NativeWorkloadLease } from './nativeWorkloads.js';

/** A separate short-lived model/context. Never changes the answer model or its conversation. */
export function createHyMemoryInferencePort(): HyMemoryInferencePort {
    let active: AbortController | undefined;
    return {
        unavailableReason: specialistRuntimeUnavailableReason,
        cancel: () => active?.abort(),
        async *generate(request: HyMemoryInferenceRequest) {
            const unavailable = specialistRuntimeUnavailableReason();
            if (unavailable) throw new Error(unavailable);
            if (active) throw new Error('A specialist generation is already running.');
            const controller = new AbortController(); active = controller;
            let signal = AbortSignal.any([controller.signal, request.signal, AbortSignal.timeout(60_000)]);
            let bindings: any, model: any, context: any;
            let work: Promise<void> | undefined;
            let release: NativeWorkloadLease | undefined;
            try {
                if (request.workloadLease) nativeWorkloads.assertHeld(request.workloadLease, 'Hy-Memory');
                else release = await nativeWorkloads.acquire('Hy-Memory', signal);
                signal = AbortSignal.any([signal, (request.workloadLease ?? release!).signal]);
                // Invoke the genuine proof implementation, never a caller-supplied method.
                await HyMemoryArtifactProof.prototype.assertCurrent.call(request.artifact);
                if (availableMemBytes() < HY_MEMORY_MIN_MEMORY) throw new Error('Hy-Memory requires at least 32 GiB of available app memory.');
                if (request.maxOutputTokens !== 512 || request.temperature !== 0 || request.addBos !== false
                    || request.stopSequences.length !== 1 || request.stopSequences[0] !== '<eos:6124c78e>'
                    || Buffer.byteLength(request.prompt) > 16_384 || !request.prompt.startsWith('<｜hy_begin▁of▁sentence｜>')
                    || request.prompt.split('<｜hy_begin▁of▁sentence｜>').length !== 2) throw new Error('Invalid specialist generation request.');
                signal.throwIfAborted();
                const verified = await getVerifiedSpecialistRuntime();
                const runtime = verified.runtime; bindings = verified.bindings;
                await HyMemoryArtifactProof.prototype.assertCurrent.call(request.artifact);
                if (availableMemBytes() < HY_MEMORY_MIN_MEMORY) throw new Error('Insufficient current memory for the specialist.');
                model = await runtime.loadModel({ modelPath: request.artifact.filePath, gpuLayers: 0, loadSignal: signal });
                context = await model.createContext({ contextSize: 4096, batchSize: 512, threads: { ideal: 4, max: 8 }, createSignal: signal });
                const prompt = bindings.LlamaText(new bindings.SpecialTokensText(request.prompt));
                if (prompt.tokenize(model.tokenizer).length + 512 > context.contextSize) throw new Error('Selected conversation exceeds the specialist context budget.');
                const queue: string[] = []; let done = false, failure: unknown, buffered = 0;
                let wake: (() => void) | undefined;
                let pending = '';
                work = generateLocalTokens(context.getSequence(), prompt.tokenize(model.tokenizer), { maxTokens: 512, temperature: 0, signal }, piece => {
                    pending += piece;
                    const marker = '<eos:6124c78e>';
                    const stop = pending.indexOf(marker);
                    let held = 0;
                    if (stop < 0) for (let n = 1; n < marker.length; n++) if (pending.endsWith(marker.slice(0, n))) held = n;
                    const ready = stop >= 0 ? pending.slice(0, stop) : pending.slice(0, pending.length - held);
                    pending = stop >= 0 ? '' : pending.slice(ready.length);
                    buffered += Buffer.byteLength(ready);
                    if (buffered > 65_536) { controller.abort(); return false; }
                    if (ready) { queue.push(ready); wake?.(); wake = undefined; }
                    return stop < 0;
                }).then(() => {
                    // A trailing partial EOS marker is protocol, never proposal text.
                    if (pending && !'<eos:6124c78e>'.startsWith(pending)) queue.push(pending);
                    done = true; wake?.();
                }, (error: unknown) => { done = true; failure = error; wake?.(); });
                while (!done || queue.length) {
                    signal.throwIfAborted();
                    if (queue.length) { yield queue.shift()!; continue; }
                    await new Promise<void>(resolve => { wake = resolve; });
                }
                if (failure) throw failure;
                await HyMemoryArtifactProof.prototype.assertCurrent.call(request.artifact);
            } finally {
                controller.abort();
                await work?.catch(() => {});
                try { await context?.dispose(); } finally {
                    try { await model?.dispose(); } finally {
                        release?.();
                        if (active === controller) active = undefined;
                    }
                }
            }
        },
    };
}
