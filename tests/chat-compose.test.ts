import { describe, it, expect } from 'vitest';
import { composeChatMessage } from '../src/utils/chatCompose.js';

/**
 * Q-284: the WS chat path used to drop attachments — the model never saw the file the user asked
 * about. composeChatMessage folds them into the model input; the caller still persists the clean
 * message. Pure, so it's tested without a WS or a model.
 */
describe('composeChatMessage', () => {
    it('returns the message unchanged when there are no attachments', () => {
        expect(composeChatMessage('hello', [])).toBe('hello');
    });

    it('prepends labeled document blocks before the message', () => {
        const out = composeChatMessage('summarize these', [
            { name: 'a.txt', content: 'alpha' },
            { name: 'b.txt', content: 'beta' },
        ]);
        expect(out).toBe('[Attached document: a.txt]\nalpha\n\n[Attached document: b.txt]\nbeta\n\nsummarize these');
        expect(out).toContain('alpha');   // the model now actually sees the content
        expect(out.indexOf('a.txt')).toBeLessThan(out.indexOf('summarize these'));   // docs first
    });

    it('handles a doc-only turn (empty message) without a dangling separator', () => {
        expect(composeChatMessage('', [{ name: 'x', content: 'y' }])).toBe('[Attached document: x]\ny');
    });
});
