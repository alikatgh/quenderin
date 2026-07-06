import { describe, expect, it, vi } from 'vitest';
import { classifyIntent, classifyWithLlmFallback, clearIntentCache, intentCacheSize } from '../src/services/intentClassifier.js';
import logger from '../src/utils/logger.js';

describe('classifyIntent', () => {
    describe('action intents', () => {
        it('classifies device actions', () => {
            expect(classifyIntent('Open Settings').intent).toBe('action');
            expect(classifyIntent('Tap the search button').intent).toBe('action');
            expect(classifyIntent('Scroll down on the page').intent).toBe('action');
            expect(classifyIntent('Click on the submit button').intent).toBe('action');
            expect(classifyIntent('Swipe left to the next screen').intent).toBe('action');
        });

        it('has high or medium confidence for clear actions', () => {
            const result = classifyIntent('Open Settings');
            expect(['high', 'medium']).toContain(result.confidence);
        });
    });

    describe('chat intents', () => {
        it('classifies knowledge questions as chat', () => {
            expect(classifyIntent('What is the capital of France?').intent).toBe('chat');
            expect(classifyIntent('Explain quantum computing').intent).toBe('chat');
            expect(classifyIntent('Who wrote Romeo and Juliet?').intent).toBe('chat');
        });

        it('classifies code requests as code', () => {
            const result = classifyIntent('Write a Python function to sort a list');
            expect(['code', 'chat']).toContain(result.intent);
        });
    });

    describe('edge cases', () => {
        it('handles empty string', () => {
            const result = classifyIntent('');
            expect(result.intent).toBeDefined();
            expect(result.confidence).toBeDefined();
        });

        it('handles very long input', () => {
            const longInput = 'a'.repeat(10000);
            const result = classifyIntent(longInput);
            expect(result.intent).toBeDefined();
        });

        it('returns consistent results for same input', () => {
            const r1 = classifyIntent('Open the camera app');
            const r2 = classifyIntent('Open the camera app');
            expect(r1.intent).toBe(r2.intent);
            expect(r1.confidence).toBe(r2.confidence);
        });
    });
});

describe('cache is bounded on BOTH write paths', () => {
    it('LLM-fallback inserts never grow the cache past MAX_CACHE_SIZE (no leak)', async () => {
        clearIntentCache();
        // Each input is low-confidence (no regex pattern matches) → the LLM fallback runs and caches.
        const llm = async () => 'CHAT';
        for (let i = 0; i < 260; i++) {
            await classifyWithLlmFallback(`ambiguous freeform phrase number ${i} here`, llm);
        }
        expect(intentCacheSize()).toBeLessThanOrEqual(200);
    });
});

describe('intent cache + logging hardening (Q-635 / Q-636)', () => {
    it('Q-635: messages sharing a 200-char prefix are classified independently (no collision)', () => {
        clearIntentCache();
        const prefix = 'x'.repeat(210);
        const rCode = classifyIntent(prefix + ' ```python\nprint(1)\n```');   // code-fence pattern
        const rChat = classifyIntent(prefix + ' good morning friend');         // no pattern → chat
        expect(rCode.intent).toBe('code');
        // With the old first-200-char key these shared a slot, so this would return the cached 'code'.
        expect(rChat.intent).toBe('chat');
    });

    it('Q-636: logs the length + result, never the message content', () => {
        const spy = vi.spyOn(logger, 'log').mockImplementation(() => undefined as unknown as void);
        classifyIntent('my secret plan to surprise Alice at 5pm');
        const logged = spy.mock.calls.map((c) => String(c[0])).join(' ');
        expect(logged).toContain('[Intent]');
        expect(logged).not.toContain('secret');
        expect(logged).not.toContain('Alice');
        spy.mockRestore();
    });
});
