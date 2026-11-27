import type { MicrophoneController } from '../lib/speech/useMicrophone.js';

export interface VoiceInputButtonProps {
    /** The local backend transcription path (POST /api/speech/transcribe). */
    readonly transcribe: (wav: Blob) => Promise<{ readonly text: string }>;
    /** Insert the transcript; the composer decides whether to auto-send. */
    readonly onTranscript: (text: string) => void;
    /** Injectable for tests / the Settings screen's mic check. */
    readonly microphone?: MicrophoneController;
    readonly disabled?: boolean;
    readonly shortcutLabel?: string;
}

/**
 * Composer mic button: hold-to-talk (pointer/keyboard) with the global
 * Ctrl/⌘+Shift+M shortcut. Shows permission prompt / denied / no-device / busy
 * states inline and never records without a user gesture.
 */
export function VoiceInputButton(_props: VoiceInputButtonProps): JSX.Element {
    throw new Error('TODO(stage2): render the mic button and wire usePushToTalk + permission states.');
}
