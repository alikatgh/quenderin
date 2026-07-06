import { describe, it, expect, vi } from 'vitest';
import { PromptBuilder } from '../src/services/agent/promptBuilder.js';
import type { MemoryService } from '../src/services/memory.service.js';

/**
 * Q-504 (perf ship-blocker): buildEnvironment runs on EVERY agent step and both memory lookups are
 * embedding RAG. The goal is constant across a run and the UI text is often unchanged between steps,
 * so the lookups are now memoized by input. These tests pin that unchanged input → ONE RAG call, and
 * that a screen change re-queries the UI RAG but never re-queries the (constant) goal RAG.
 */
function fakeMemory() {
    const findSimilarGoal = vi.fn().mockResolvedValue(null);
    const findRelevantCorrections = vi.fn().mockResolvedValue([]);
    const memory = { findSimilarGoal, findRelevantCorrections } as unknown as MemoryService;
    return { memory, findSimilarGoal, findRelevantCorrections };
}

describe('PromptBuilder RAG memoization (Q-504)', () => {
    it('runs each embedding RAG ONCE across steps when goal and UI text are unchanged', async () => {
        const { memory, findSimilarGoal, findRelevantCorrections } = fakeMemory();
        const pb = new PromptBuilder(memory);

        await pb.buildEnvironment('open settings', '<ui>A</ui>', []);
        await pb.buildEnvironment('open settings', '<ui>A</ui>', ['tapped X']);
        await pb.buildEnvironment('open settings', '<ui>A</ui>', ['tapped X', 'tapped Y']);

        expect(findSimilarGoal).toHaveBeenCalledTimes(1);        // 3 steps, 1 embed — the fix
        expect(findRelevantCorrections).toHaveBeenCalledTimes(1);
    });

    it('re-queries the UI RAG when the screen changes, but never re-queries the constant goal RAG', async () => {
        const { memory, findSimilarGoal, findRelevantCorrections } = fakeMemory();
        const pb = new PromptBuilder(memory);

        await pb.buildEnvironment('goal', '<ui>screen 1</ui>', []);
        await pb.buildEnvironment('goal', '<ui>screen 2</ui>', []);   // screen changed

        expect(findSimilarGoal).toHaveBeenCalledTimes(1);         // goal unchanged → cached
        expect(findRelevantCorrections).toHaveBeenCalledTimes(2); // UI changed → re-embedded
    });
});
