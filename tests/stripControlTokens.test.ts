/**
 * Tests for src/utils/stripControlTokens.ts — strips LLM control/special tokens
 * from generated text. Both exports are pure functions with no external deps,
 * so we import and assert their REAL behavior against exact expected outputs.
 *
 * Token patterns enumerated from the source (CONTROL_TOKEN_PATTERNS):
 *   ChatML:        <|im_start|>(role)?\n?  and  <|im_end|>\n?
 *   end-of-turn:   <|end|>  <|eot_id|>  <|end_of_text|>
 *   legacy EOS:    </s>
 *   tool calls:    <tool_call>...</tool_call> (whole block + trailing ws)
 *   stray BOS:     <s>
 *   Llama3 header: <|start_header_id|>...<|end_header_id|>\n?
 */
import { describe, expect, it } from 'vitest';
import {
    stripControlTokens,
    stripControlTokensWithOptions,
} from '../src/utils/stripControlTokens.js';

describe('stripControlTokens', () => {
    it('passes normal text through unchanged', () => {
        expect(stripControlTokens('Hello, world!')).toBe('Hello, world!');
        expect(stripControlTokens('No special tokens here. 1 < 2 > 0.')).toBe(
            'No special tokens here. 1 < 2 > 0.'
        );
    });

    it('trims leading/trailing whitespace from the result', () => {
        expect(stripControlTokens('   spaced out   ')).toBe('spaced out');
        expect(stripControlTokens('\n\ttabbed\n')).toBe('tabbed');
    });

    it('returns empty string for content that is only control tokens', () => {
        expect(stripControlTokens('<|im_start|>assistant\n<|im_end|>')).toBe('');
        expect(stripControlTokens('<s></s>')).toBe('');
    });

    it('removes ChatML <|im_start|> markers with role and trailing newline', () => {
        expect(stripControlTokens('<|im_start|>assistant\nHello there')).toBe(
            'Hello there'
        );
        expect(stripControlTokens('<|im_start|>system\nYou are a bot')).toBe(
            'You are a bot'
        );
        expect(stripControlTokens('<|im_start|>user\nhi')).toBe('hi');
        expect(stripControlTokens('<|im_start|>tool\nresult')).toBe('result');
    });

    it('removes ChatML <|im_start|> markers without a role', () => {
        expect(stripControlTokens('<|im_start|>\nbody')).toBe('body');
    });

    it('removes ChatML <|im_end|> markers, consuming following whitespace via \\s*', () => {
        // The <|im_end|>\s*\n? pattern's \s* greedily eats the newline after the
        // marker, so the "\n" between "Done" and "More" is removed too.
        expect(stripControlTokens('Done<|im_end|>\nMore')).toBe('DoneMore');
        expect(stripControlTokens('end<|im_end|>')).toBe('end');
    });

    it('strips a full ChatML wrapped turn down to its inner text', () => {
        const input = '<|im_start|>assistant\nThe answer is 42.<|im_end|>';
        expect(stripControlTokens(input)).toBe('The answer is 42.');
    });

    it('removes Llama/Phi end-of-turn tokens', () => {
        expect(stripControlTokens('foo<|end|>')).toBe('foo');
        expect(stripControlTokens('foo<|eot_id|>')).toBe('foo');
        expect(stripControlTokens('foo<|end_of_text|>')).toBe('foo');
        expect(stripControlTokens('a<|end|>b<|eot_id|>c<|end_of_text|>d')).toBe(
            'abcd'
        );
    });

    it('removes legacy EOS </s> and stray BOS <s> tokens', () => {
        expect(stripControlTokens('answer</s>')).toBe('answer');
        expect(stripControlTokens('<s>answer')).toBe('answer');
        expect(stripControlTokens('<s>wrapped</s>')).toBe('wrapped');
    });

    it('strips an entire <tool_call> block including its trailing whitespace', () => {
        const input = 'Before <tool_call>{"name":"x","args":{}}</tool_call> After';
        // The pattern also consumes trailing whitespace (\s*) after </tool_call>,
        // so the space before "After" is removed too.
        expect(stripControlTokens(input)).toBe('Before After');
    });

    it('strips a multiline <tool_call> block', () => {
        const input = 'Reply:\n<tool_call>\n{\n  "name": "search"\n}\n</tool_call>\nok';
        expect(stripControlTokens(input)).toBe('Reply:\nok');
    });

    it('removes Llama 3+ header blocks <|start_header_id|>...<|end_header_id|>', () => {
        const input = '<|start_header_id|>assistant<|end_header_id|>\nHi!';
        expect(stripControlTokens(input)).toBe('Hi!');
    });

    it('is case-insensitive for the marker tokens', () => {
        expect(stripControlTokens('text</S>')).toBe('text');
        expect(stripControlTokens('<|IM_END|>kept')).toBe('kept');
    });

    it('removes all targeted tokens from a mixed, realistic stream', () => {
        const input =
            '<s><|im_start|>assistant\nHere is the result.' +
            '<tool_call>{"name":"calc"}</tool_call>' +
            'Final answer.<|im_end|><|eot_id|></s>';
        expect(stripControlTokens(input)).toBe(
            'Here is the result.Final answer.'
        );
    });
});

describe('stripControlTokensWithOptions', () => {
    it('defaults to trimming when no options are passed', () => {
        expect(stripControlTokensWithOptions('  hi  ')).toBe('hi');
    });

    it('trims when { trim: true } is passed explicitly', () => {
        expect(stripControlTokensWithOptions('  hi  ', { trim: true })).toBe('hi');
    });

    it('preserves surrounding whitespace when { trim: false }', () => {
        expect(stripControlTokensWithOptions('  hi  ', { trim: false })).toBe(
            '  hi  '
        );
    });

    it('with { trim: false }, removes control tokens but keeps the whitespace they leave behind', () => {
        // <|im_start|>assistant\n is removed, leaving the leading spaces + the
        // trailing newline that followed the stripped text. Nothing is trimmed.
        const input = '  <|im_start|>assistant\nHello  ';
        expect(stripControlTokensWithOptions(input, { trim: false })).toBe(
            '  Hello  '
        );
    });

    it('with { trim: false }, preserves whitespace that sits between non-token text', () => {
        // The leading/trailing spaces are token-free, so removing the inner
        // <|im_end|> marker leaves them untouched (no trim).
        expect(
            stripControlTokensWithOptions('  a<|im_end|>b  ', { trim: false })
        ).toBe('  ab  ');
    });
});
