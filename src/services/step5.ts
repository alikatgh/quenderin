/** Step 5 uses its official CUDA backend; it is never disguised as a llama.cpp model. */
export const STEP5_MODEL_REVISION = '364b3b03fed2477aa0953fe855a2c4c8c48ee3cc';
export const STEP5_BACKEND_REVISION = 'e177c621f2b8ae1be06190bc34eef84646e54f11';
export interface Step5Message { role: 'user' | 'assistant'; content: string }
export interface Step5Answer { text: string; truncated: boolean }

export function step5Endpoint(value: unknown): URL {
    if (typeof value !== 'string' || value.length > 2048) throw new Error('Enter the URL of your Step 5 gateway.');
    const url = new URL(value);
    // Loopback is a literal address, never a DNS name that could be rebound.
    const local = ['127.0.0.1', '[::1]'].includes(url.hostname);
    if (url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
        !(url.protocol === 'https:' || (url.protocol === 'http:' && local))) {
        throw new Error('Use an HTTPS origin or http://127.0.0.1:18000. Credentials, paths and query strings are unavailable.');
    }
    return url;
}

export function step5Messages(value: unknown): Step5Message[] {
    if (!Array.isArray(value) || value.length < 1 || value.length > 16) throw new Error('Use 1–16 messages per Step 5 conversation.');
    let bytes = 0;
    const messages = value.map((raw, index) => {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Invalid Step 5 message.');
        const item = raw as Record<string, unknown>;
        const role = index % 2 === 0 ? 'user' : 'assistant';
        if (Object.keys(item).some(key => !['role', 'content'].includes(key)) || item.role !== role ||
            typeof item.content !== 'string' || !item.content.trim() || item.content.includes('\0') || Buffer.byteLength(item.content) > 8192) {
            throw new Error('Step 5 messages must alternate user and assistant, with at most 8,192 UTF-8 bytes each.');
        }
        bytes += Buffer.byteLength(item.content);
        return { role, content: item.content } as Step5Message;
    });
    if (messages.at(-1)?.role !== 'user' || bytes > 32768) throw new Error('End with a user message and keep the selected conversation below 32 KiB.');
    return messages;
}

async function boundedJson(response: Response, maxBytes: number): Promise<unknown> {
    if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error(`Step 5 gateway returned HTTP ${response.status}.`); }
    const reader = response.body.getReader();
    const pieces: Uint8Array[] = []; let bytes = 0;
    try {
        while (true) {
            const { value, done } = await reader.read(); if (done) break;
            bytes += value.byteLength;
            if (bytes > maxBytes) throw new Error('Step 5 gateway exceeded its response limit.');
            pieces.push(value);
        }
        return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(pieces)));
    } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}

export function validateStep5Contract(raw: unknown): void {
    const item = raw as Record<string, unknown> | null;
    if (!item || item.protocol !== 1 || item.modelRevision !== STEP5_MODEL_REVISION || item.backendRevision !== STEP5_BACKEND_REVISION ||
        item.artifactsVerified !== true || item.ready !== true || item.maxOutputTokens !== 1024 || item.maxConcurrentRequests !== 1) {
        throw new Error('This gateway is not ready with the pinned Step 5 backend and complete verified artifacts. Start scripts/run_step5_backend.py on your CUDA host.');
    }
}

export function validateStep5Answer(raw: unknown): Step5Answer {
    const item = raw as Record<string, unknown> | null;
    if (!item || typeof item.text !== 'string' || !item.text.trim() || Buffer.byteLength(item.text) > 256 * 1024 || typeof item.truncated !== 'boolean' ||
        /<\/?(?:think|tool_call)|<\|(?:im_start|im_end|channel)|<｜/iu.test(item.text)) {
        throw new Error('The Step 5 gateway did not return a complete final answer. Private reasoning and tool output cannot be displayed.');
    }
    return { text: item.text, truncated: item.truncated };
}

/** One foreground operation, no automatic retry, provisioning or background requests. */
export class Step5Client {
    private operation?: AbortController;
    constructor(private readonly transport: typeof fetch = fetch) {}
    cancel(): void { this.operation?.abort(); }
    private async run<T>(endpoint: unknown, work: (url: URL, signal: AbortSignal) => Promise<T>, parent?: AbortSignal): Promise<T> {
        if (this.operation) throw new Error('A Step 5 request is already running.');
        const url = step5Endpoint(endpoint); const controller = new AbortController(); this.operation = controller;
        const abort = () => controller.abort(); parent?.addEventListener('abort', abort, { once: true });
        if (parent?.aborted) controller.abort();
        const timeout = setTimeout(abort, 180_000);
        try { return await work(url, controller.signal); }
        finally { clearTimeout(timeout); parent?.removeEventListener('abort', abort); if (this.operation === controller) this.operation = undefined; }
    }
    private async contract(url: URL, signal: AbortSignal): Promise<void> {
        const response = await this.transport(new URL('/quenderin/step5', url), { signal, redirect: 'error', credentials: 'omit', cache: 'no-store' });
        validateStep5Contract(await boundedJson(response, 8192));
    }
    async check(endpoint: unknown, signal?: AbortSignal): Promise<void> { return this.run(endpoint, (url, current) => this.contract(url, current), signal); }
    async answer(endpoint: unknown, rawMessages: unknown, signal?: AbortSignal): Promise<Step5Answer> {
        const messages = step5Messages(rawMessages);
        return this.run(endpoint, async (url, current) => {
            await this.contract(url, current);
            const response = await this.transport(new URL('/quenderin/step5/answer', url), {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ messages }),
                signal: current, redirect: 'error', credentials: 'omit', cache: 'no-store',
            });
            return validateStep5Answer(await boundedJson(response, 300 * 1024));
        }, signal);
    }
}
