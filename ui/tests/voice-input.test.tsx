import { describe, it } from 'vitest';

/**
 * Stage 2 implements useMicrophone, usePushToTalk, the WAV encoder and
 * VoiceInputButton. All tests mock getUserMedia/MediaRecorder/audio decoding
 * and the transcribe API; no real microphone and no network.
 */
describe('composer voice input', () => {
    it.todo('requests permission on first mic press and shows prompt copy before that');
    it.todo('states granted / denied / no-device / unsupported explicitly');
    it.todo('denied state shows how-to-fix text for the current OS');
    it.todo('Electron macOS exposes the systemPreferences media-access hint');
    it.todo('hold-to-talk records only while pressed and stops on release');
    it.todo('keyboard shortcut Ctrl/⌘+Shift+M starts and stops recording');
    it.todo('Escape or blur cancels without calling transcribe');
    it.todo('encodes the capture as 16 kHz mono 16-bit PCM WAV before upload');
    it.todo('posts the WAV to the mocked /api/speech/transcribe and inserts the transcript');
    it.todo('auto-send inserts and sends only when settings.autoSend is true');
    it.todo('sets the aria-busy/disabled state while transcribing');
    it.todo('shows a retryable inline error when transcription fails');
    it.todo('releases the MediaStream tracks on unmount');
});
