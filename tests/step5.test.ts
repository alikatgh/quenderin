import { describe, expect, it } from 'vitest';
import { Step5Client, STEP5_BACKEND_REVISION, STEP5_MODEL_REVISION, step5Endpoint, step5Messages, validateStep5Answer } from '../src/services/step5.js';

const contract = { protocol: 1, modelRevision: STEP5_MODEL_REVISION, backendRevision: STEP5_BACKEND_REVISION,
    artifactsVerified: true, ready: true, maxOutputTokens: 1024, maxConcurrentRequests: 1 };
describe('Step 5 official backend connector', () => {
    it('permits only explicit secure origins and literal loopback HTTP', () => {
        expect(step5Endpoint('http://127.0.0.1:18000').origin).toBe('http://127.0.0.1:18000');
        expect(step5Endpoint('https://my-cuda-host.example').protocol).toBe('https:');
        for (const url of ['http://localhost:18000', 'http://server.example', 'file:///tmp/x', 'https://user:password@host', 'https://host/path', 'https://host/?token=x', 'https://host/#x']) {
            expect(() => step5Endpoint(url)).toThrow();
        }
    });
    it('bounds selected history and enforces roles without injecting system/tool messages', () => {
        expect(step5Messages([{ role: 'user', content: 'hello' }])).toHaveLength(1);
        for (const messages of [[], [{ role: 'system', content: 'x' }], [{ role: 'assistant', content: 'x' }],
            [{ role: 'user', content: 'a', tool_calls: [] }], [{ role: 'user', content: 'é'.repeat(4097) }],
            Array.from({ length: 17 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', content: 'a' }))]) {
            expect(() => step5Messages(messages)).toThrow();
        }
    });
    it('does not transmit prompts when provenance or readiness mismatches', async () => {
        let calls = 0;
        const transport = (async () => { calls++; return Response.json({ ...contract, backendRevision: 'wrong' }); }) as typeof fetch;
        await expect(new Step5Client(transport).answer('http://127.0.0.1:18000', [{ role: 'user', content: 'private' }])).rejects.toThrow(/not ready/);
        expect(calls).toBe(1);
    });
    it('uses the fixed bounded gateway route, no redirects, retries or local auth forwarding', async () => {
        const calls: { url: string; init?: RequestInit }[] = [];
        const transport = (async (url: URL, init?: RequestInit) => {
            calls.push({ url: String(url), init });
            return Response.json(calls.length === 1 ? contract : { text: 'Final answer', truncated: false });
        }) as typeof fetch;
        expect(await new Step5Client(transport).answer('http://127.0.0.1:18000', [{ role: 'user', content: 'Hello' }])).toEqual({ text: 'Final answer', truncated: false });
        expect(calls.map(call => call.url)).toEqual(['http://127.0.0.1:18000/quenderin/step5', 'http://127.0.0.1:18000/quenderin/step5/answer']);
        expect(calls.every(call => call.init?.redirect === 'error' && call.init.credentials === 'omit')).toBe(true);
        expect(calls[1].init?.headers).toEqual({ 'Content-Type': 'application/json' });
    });
    it('rejects oversized chunked responses before JSON decode', async () => {
        const transport = (async () => new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(8193)); controller.close(); } }))) as typeof fetch;
        await expect(new Step5Client(transport).check('http://127.0.0.1:18000')).rejects.toThrow(/response limit/);
    });
    it('holds one operation and cancels its actual transport', async () => {
        const transport = (async (_url: URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener('abort', () => reject(new Error('cancelled')), { once: true });
        })) as typeof fetch;
        const client = new Step5Client(transport);
        const pending = client.check('http://127.0.0.1:18000');
        await expect(client.check('http://127.0.0.1:18000')).rejects.toThrow(/already running/);
        client.cancel(); await expect(pending).rejects.toThrow(/cancelled/);
    });
    it('never displays private reasoning, wire tokens or tool calls as final content', () => {
        for (const text of ['', '<think>private</think>answer', '<tool_call>x', '<|channel|>analysis', '<｜hy_User｜>']) expect(() => validateStep5Answer({ text, truncated: false })).toThrow();
        expect(validateStep5Answer({ text: 'Hello', truncated: true })).toEqual({ text: 'Hello', truncated: true });
    });
});
