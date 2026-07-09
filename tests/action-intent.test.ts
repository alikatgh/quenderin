import { describe, it, expect } from 'vitest';
import { looksLikeComputerTask } from '../src/services/capability/actionIntent.js';

/// The TS twin of Swift/Kotlin ActionIntent — same pattern strings, same fixtures.
describe('ActionIntent (twin of Swift/Kotlin)', () => {
    it('flags operate-the-computer requests', () => {
        expect(looksLikeComputerTask('organize the files in my downloads folder')).toBe(true);
        expect(looksLikeComputerTask('open Safari and read the news')).toBe(true);
        expect(looksLikeComputerTask('draft an email to my boss')).toBe(true);
        expect(looksLikeComputerTask('move these files into a folder')).toBe(true);
        expect(looksLikeComputerTask('create a new folder called Taxes')).toBe(true);
        expect(looksLikeComputerTask('run the shortcut for my morning routine')).toBe(true);
    });
    it('does not flag questions or chit-chat (precision over recall)', () => {
        expect(looksLikeComputerTask('what is 2 plus 2')).toBe(false);
        expect(looksLikeComputerTask('what is the capital of France')).toBe(false);
        expect(looksLikeComputerTask('tell me a joke')).toBe(false);
        expect(looksLikeComputerTask('what can you do')).toBe(false);
    });
});
