import { withContextAbort } from './contextAbort.js';

/** Public node-llama-cpp token API: no implicit BOS, template inference or context truncation. */
export async function generateLocalTokens(sequence: any, tokens: number[], options: {
    maxTokens: number; temperature: number; signal?: AbortSignal; repeatPenalty?: { penalty?: number; lastTokens?: number };
}, emit: (piece: string) => boolean | void): Promise<void> {
    if (!Number.isSafeInteger(options.maxTokens) || options.maxTokens < 1 || options.maxTokens > 2048
        || !Number.isFinite(options.temperature) || options.temperature < 0) throw new Error('Invalid bounded generation options.');
    const cap = options.maxTokens;
    if (tokens.length + cap > sequence.contextSize) throw new Error('Prompt and reply exceed the available context.');
    options.signal?.throwIfAborted();
    await withContextAbort(sequence, options.signal, async () => {
        // Full publisher history is supplied explicitly. Never cut through its role/channel framing.
        await sequence.clearHistory();
        const generated: number[] = [];
        let emitted = '';
        const repeat = options.repeatPenalty;
        const iterator = sequence.evaluate(tokens, {
            temperature: options.temperature, yieldEogToken: true,
            ...(repeat ? { repeatPenalty: { penalty: repeat.penalty, maxPunishTokens: repeat.lastTokens ?? 256,
                punishTokens: () => generated.slice(-(repeat.lastTokens ?? 256)) } } : {}),
        });
        for await (const token of iterator) {
            options.signal?.throwIfAborted();
            generated.push(token);
            // Re-decode the bounded reply to retain incomplete UTF-8 across token boundaries.
            // Trailing replacement characters may be an unfinished scalar and are held, never leaked.
            const stable = sequence.model.detokenize(generated, true).replace(/\uFFFD+$/u, '');
            if (stable.length > 1_048_576 || !stable.startsWith(emitted)) throw new Error('Malformed or oversized token stream.');
            const piece = stable.slice(emitted.length); emitted = stable;
            if (piece && emit(piece) === false) break;
            options.signal?.throwIfAborted();
            if (sequence.model.isEogToken?.(token) || generated.length >= cap) break;
        }
        options.signal?.throwIfAborted();
    });
}
