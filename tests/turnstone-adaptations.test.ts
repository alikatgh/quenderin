import { describe, expect, it, vi } from 'vitest';
import { LlmService } from '../src/services/llm.service.js';
vi.mock('node-llama-cpp', () => ({
    getLlama: vi.fn(async () => { throw new Error('no runtime in this test'); }),
    LlamaLogLevel: { disabled: 'disabled' },
    LlamaModel: class {},
    LlamaContext: class {},
    LlamaChatSession: class {},
}));
import {
    decideModelHold,
    EXPERIMENTAL_SOURCE_NOTICE,
    explicitSelection,
} from '../src/services/modelSelectionHold.js';
import { GuidanceNotebook } from '../src/services/namedGuidance.js';
import { ConversationWriter } from '../src/services/conversationWriter.js';

describe('Turnstone adaptations', () => {
    it('keeps an explicit model instead of recommending a substitute', () => {
        // adapt:model-hold-recommend
        expect(decideModelHold({ explicitModelId: '  ', availability: 'missing', evidence: 'ordinary' }).kind).toBe('recommend');
        // adapt:model-hold-missing
        const missing = decideModelHold({ explicitModelId: 'qwen3-4b', availability: 'missing', evidence: 'ordinary' });
        expect(missing).toMatchObject({
            kind: 'wait',
            message: '"qwen3-4b" is not on this device. This choice stays selected and was not replaced. Choose another model to continue.',
        });
        // adapt:model-hold-unreadable
        const unreadable = decideModelHold({ explicitModelId: 'gone', availability: 'unreadable', evidence: 'ordinary' });
        expect(unreadable.kind === 'wait' && unreadable.message).toContain('cannot be read');
        // adapt:model-hold-incompatible
        const incompatible = decideModelHold({ explicitModelId: 'qwen3-4b', availability: 'incompatible', evidence: 'ordinary' });
        expect(incompatible.kind === 'wait' && incompatible.message).toContain('does not run in this build');
        // adapt:model-hold-blocked
        const blocked = decideModelHold({ explicitModelId: 'bonsai2-27b', availability: 'blocked', evidence: 'experimental-source' });
        expect(blocked.kind === 'wait' && blocked.message).toContain('does not fit the current memory gate');
        expect(blocked.kind === 'wait' && blocked.message).toContain(EXPERIMENTAL_SOURCE_NOTICE);
        // adapt:model-hold-experimental-notice
        const experimental = decideModelHold({ explicitModelId: 'bonsai2-27b', availability: 'present', evidence: 'experimental-source' });
        expect(experimental).toMatchObject({ kind: 'use', notice: EXPERIMENTAL_SOURCE_NOTICE });
        const ordinary = decideModelHold({ explicitModelId: 'qwen3-4b', availability: 'present', evidence: 'ordinary' });
        expect(ordinary).toMatchObject({ kind: 'use', notice: '' });
        expect(explicitSelection({
            explicit: true, modelId: 'bonsai2-27b', catalogHit: true, runtimeCanLoad: true,
            filePresent: true, memoryCanLoad: false, experimentalSource: true,
        }).action).toBe('wait');
        expect(explicitSelection({
            explicit: false, modelId: 'qwen3-4b', catalogHit: false, runtimeCanLoad: false,
            filePresent: false, memoryCanLoad: false, experimentalSource: false,
        }).action).toBe('fallback');
    });

    it('applies one named note and leaves the model alone', () => {
        const notes = new GuidanceNotebook();
        // adapt:guidance-select-only
        expect(notes.save('Packing', 'Use {{model}} for {{other}}')).toEqual({ ok: true });
        expect(notes.render('Qwen3 4B')).toBeNull();
        expect(notes.select('Missing').ok).toBe(false);
        // adapt:guidance-one-active
        expect(notes.save('Travel', 'Short answers.')).toEqual({ ok: true });
        expect(notes.select('Packing').ok).toBe(true);
        expect(notes.select('Travel').ok).toBe(true);
        expect(notes.render('Qwen3 4B')).toContain('Short answers.');
        expect(notes.render('Qwen3 4B')).not.toContain('{{model}}');
        // adapt:guidance-placeholder
        notes.select('Packing');
        const rendered = notes.render('Qwen3 4B') ?? '';
        expect(rendered).toContain('Use Qwen3 4B for {{other}}');
        // adapt:guidance-no-model-knob
        expect(rendered).toContain('does not change the model or which tools can run');
        expect(rendered).not.toContain('temperature');
        expect(notes.save('', 'x').ok).toBe(false);
    });

    it('allows one live writer and recovers a crashed one after its lifetime', () => {
        const writers = new ConversationWriter();
        // adapt:writer-one-owner
        const first = writers.claim('chat-1', 'writer-a', 1_000, 500);
        const second = writers.claim('chat-1', 'writer-b', 1_200, 500);
        expect(first.ok).toBe(true);
        expect(second).toMatchObject({
            ok: false,
            message: 'This conversation already has a live reply from "writer-a". Wait for it to finish.',
        });
        expect(first.ok && writers.release(first.permit, 1_200)).toBe(true);
        // adapt:writer-expiry
        const expired = writers.claim('chat-1', 'writer-a', 2_000, 100);
        const recovered = writers.claim('chat-1', 'writer-c', 2_100, 100);
        expect(expired.ok && recovered.ok && recovered.permit.writerId).toBe('writer-c');
        // adapt:writer-stale-release
        expect(expired.ok && writers.release(expired.permit, 2_100)).toBe(false);
        expect(recovered.ok && writers.release({ ...recovered.permit, token: 'other' }, 2_100)).toBe(false);
        expect(recovered.ok && writers.release(recovered.permit, 2_100)).toBe(true);
    });

    it('refuses a second desktop chat writer without starting another reply', async () => {
        const svc = new LlmService();
        const first = svc.generalChat('hello');
        await expect(svc.generalChat('again')).rejects.toThrow(/live reply/);
        await expect(first).rejects.toThrow();
        await expect(svc.generalChat('later')).rejects.toThrow(/^(?!.*live reply)/s);
    });
});
