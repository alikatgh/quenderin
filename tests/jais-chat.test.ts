import { describe, expect, it } from 'vitest';
import { ChatWrapper, LlamaText, SpecialTokensText, SpecialToken } from 'node-llama-cpp';
import { JaisFinalChannelFilter } from '../src/services/jaisChat.js';
import { jaisChatWrapper } from '../src/services/weeklyChatWrappers.js';

describe('Jais final-channel boundaries', () => {
    for (const closing of ['</ifm|think>', '</ifm|think_faster>', '</ifm|think_fast>']) {
        const wire = `private reasoning${closing}مرحباً world<|ifm|im_end|>hidden next turn`;
        it(`hides reasoning and protocol at every split: ${closing}`, () => {
            for (let split = 0; split <= wire.length; split++) {
                const filter = new JaisFinalChannelFilter();
                expect(filter.feed(wire.slice(0, split)) + filter.feed(wire.slice(split)) + filter.finish())
                    .toBe('مرحباً world');
            }
        });
    }
    it('never flushes unfinished reasoning or protocol', () => {
        expect(JaisFinalChannelFilter.finalText('private reasoning</ifm|thi')).toBe('');
        expect(JaisFinalChannelFilter.finalText('private</ifm|think>answer<|ifm|im_')).toBe('answer');
    });
    it('uses publisher history framing and opens a private low-reasoning channel', () => {
        const wrapper = jaisChatWrapper({ ChatWrapper, LlamaText, SpecialTokensText, SpecialToken });
        const context = wrapper.generateContextState({ chatHistory: [
            { type: 'system', text: 'Be helpful.' }, { type: 'user', text: 'Hello' },
            { type: 'model', response: ['Hi'] }, { type: 'user', text: 'Explain' },
            { type: 'model', response: [] },
        ] });
        const text = context.contextText.toString();
        expect(text).toContain('<|ifm|im_start|>assistant<ifm|think>\n</ifm|think>Hi<|ifm|im_end|>');
        expect(text).toContain('<|ifm|im_start|>user\nExplain<|ifm|im_end|><|ifm|im_start|>assistant\n');
        expect(context.noPrefixTrigger.segmentType).toBe('thought');
        expect(context.noPrefixTrigger.inject.toString()).toBe('<ifm|think_faster>\n');
        expect(() => wrapper.generateContextState({ chatHistory: [], availableFunctions: { doSomething: {} } }))
            .toThrow('text chat only');
    });
});
