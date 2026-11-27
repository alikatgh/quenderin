import { describe, it } from 'vitest';

/**
 * Stage 2 adds axe-core coverage for the new step and composer control. Follow
 * ui/tests/a11y.test.tsx (color-contrast disabled in jsdom; roles/names run).
 */
describe('a11y: voice STT picker', () => {
    it.todo('VoiceModelStep has no axe violations with the full 29-model table open');
    it.todo('Recommended / More accurate cards are a labelled radio group');
    it.todo('filters are labelled checkboxes and the search has an accessible name');
    it.todo('download progress exposes role=progressbar with aria-valuenow/min/max');
    it.todo('error states are role=alert and linked to the failing action');
    it.todo('voice input button has an accessible name including its shortcut');
    it.todo('mic permission denied copy is announced and reachable by keyboard');
});
