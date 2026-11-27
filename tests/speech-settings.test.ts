import { describe, it } from 'vitest';

/**
 * Stage 2 implements src/services/speech/speechSettings.ts. Tests use a temp
 * directory and injected fs/clock; never the user's real ~/.quenderin.
 */
describe('speech settings', () => {
    it.todo('defaults to voice off, no model and autoSend false');
    it.todo('persists and reloads the chosen modelId and voiceEnabled');
    it.todo('writes atomically (temp file + rename) with mode 0600');
    it.todo('treats a missing file as defaults without throwing');
    it.todo('treats corrupt JSON as defaults and does not crash startup');
    it.todo('rejects unknown keys and non-boolean/non-string values');
    it.todo('reset deletes the file and returns defaults');
});
