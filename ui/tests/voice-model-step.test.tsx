import { describe, it } from 'vitest';

/**
 * Stage 2 implements ui/src/components/onboarding/VoiceModelStep.tsx and
 * SpeechModelTable.tsx against a mocked /api/speech/models payload generated
 * from shared/handy-speech-catalog.json.
 */
describe('VoiceModelStep (onboarding step 2)', () => {
    it.todo('renders "Optional" labelling and both Recommended (Parakeet) and More accurate (Qwen3-ASR 1.7B) cards');
    it.todo('shows the catalog-derived "Show all 29 models" label, never a hard-coded 29');
    it.todo('expands the table on Show all and collapses it on request');
    it.todo('filters by search text over name and description');
    it.todo('filters by Live preview from capabilities.streaming');
    it.todo('filters by Translates from capabilities.translate and combines with Live preview');
    it.todo('renders EN grade, SPEED bars and formatted SIZE columns from the API payload');
    it.todo('shows "Needs newer speech engine" and disables download for minEngine > runtime');
    it.todo('renders "Download 697 MB" and the "Downloads while you finish setup" note');
    it.todo('shows byte/percent progress, pause, resume, cancel and retry states');
    it.todo('renders a clear error for each download error kind (network, disk full, checksum, 404, 416)');
    it.todo('skip path calls onSkip and keeps voice off');
    it.todo('keyboard: typing opens the full list with the typed query, Escape closes it');
    it.todo('selecting a model updates the primary button and download target');
});
