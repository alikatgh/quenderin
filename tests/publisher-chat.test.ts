import fs from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import { generateLocalTokens } from '../src/services/localTokenGeneration.js';
import { PublisherChatSession, PublisherOutputFilter, publisherPrompt } from '../src/services/publisherChat.js';

const cases = JSON.parse(fs.readFileSync(new URL('../scripts/tests/fixtures/experimental-model-prompts.json', import.meta.url), 'utf8')).cases;
describe('Beam actual publisher session', () => {
    it('matches the immutable official single-turn and reasoning-history template outputs', () => {
        for (const c of cases.filter((entry: any) => entry.name.startsWith('beam-'))) {
            const instructions = c.messages.filter((m: any) => m.role === 'system').map((m: any) => m.content).join('\n\n');
            const history = c.messages.filter((m: any) => m.role !== 'system').map((m: any) => ({ role: m.role, text: m.content, reasoning: m.reasoning_content }));
            expect(publisherPrompt('beam', instructions, history)).toBe(c.expected);
        }
        expect(publisherPrompt('beam', '', [{ role: 'assistant', text: 'Restored final' }]))
            .toContain('<|channel|>analysis<|message|><|end|><|start|>assistant<|channel|>final<|message|>Restored final<|return|>');
    });
    it('hides analysis and wire tags at every possible chunk boundary', () => {
        const wire = '<|channel|>analysis<|message|>private<|end|><|start|>assistant<|channel|>final<|message|>Hello 🌲<|return|>leak';
        for (let cut = 0; cut <= wire.length; cut++) {
            const parser = new PublisherOutputFilter('beam');
            expect(parser.feed(wire.slice(0, cut)) + parser.feed(wire.slice(cut)) + parser.finish()).toBe('Hello 🌲');
            expect(parser.reasoning).toBe('private');
        }
        for (const wire of ['<|channel|>analysis<|message|>private', '<|channel|>final to=tool<|message|>leak', 'x'.repeat(2048), '<|channel|>final<|message|><|unknown|>leak']) {
            const parser = new PublisherOutputFilter('beam');
            expect(parser.feed(wire) + parser.finish()).toBe('');
        }
    });
    it('drives the real completion adapter, streams final only and retains transient analysis for the next turn', async () => {
        const prompts: string[] = [];
        const generate = vi.fn(async function* (_tokens: number[], _options: any) {
            for (const c of '<|channel|>analysis<|message|>private<|end|><|start|>assistant<|channel|>final<|message|>Answer') yield c.charCodeAt(0);
        });
        const sequence = { context: { _ctx: { getQuenderinContextAbortABI: () => 1, resetQuenderinAbort: vi.fn(), requestQuenderinAbort: vi.fn() } }, contextSize: 4096, clearHistory: vi.fn(), dispose: vi.fn(), evaluate: generate,
            model: { tokenizer: {}, detokenize: (tokens: number[]) => String.fromCharCode(...tokens) } };
        const bindings = { SpecialTokensText: class { constructor(readonly text: string) {} },
            LlamaText: (part: any) => ({ text: part.text, tokenize: () => { prompts.push(part.text); return [1, 2]; } }) };
        const session = new PublisherChatSession('beam', sequence, 'Short answers', bindings);
        const stream = vi.fn();
        expect(await session.prompt('Hello', { maxTokens: 512, onTextChunk: stream })).toBe('Answer');
        expect(stream.mock.calls.flat().join('')).toBe('Answer');
        await session.prompt('Continue', { maxTokens: 512 });
        expect(prompts.at(-1)).toContain('<|channel|>analysis<|message|>private<|end|>');
        expect(prompts.at(-1)).toContain('<|channel|>final<|message|>Answer<|return|>');
        await expect(session.prompt('tools', { functions: { tool: {} } })).rejects.toThrow('text chat only');
        await expect(session.prompt('grammar', { grammar: {} })).rejects.toThrow('text chat only');
        expect(generate).toHaveBeenCalledTimes(2);
    });
    it('rejects nonfinite or oversized raw token budgets before evaluating', async () => {
        const sequence = { evaluate: vi.fn() };
        for (const cap of [NaN, Infinity, -1, 2049, 1.5]) {
            await expect(generateLocalTokens(sequence, [], { maxTokens: cap, temperature: 0 }, () => {})).rejects.toThrow('Invalid bounded');
        }
        expect(sequence.evaluate).not.toHaveBeenCalled();
    });
    it('uses the desktop Muse final-channel adapter with unchanged native framing', () => {
        expect(publisherPrompt('muse', '', [{ role: 'user', text: 'Hi' }])).toContain('Reasoning strength: 16.');
        const filter = new PublisherOutputFilter('muse');
        expect(filter.feed(' to=self<|message|>hidden<|eom|><|start|>assistant to=user<|message|>Hello<|eot|>leak')).toBe('Hello');
    });
});
