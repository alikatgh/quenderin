/**
 * Microphone permission + push-to-talk for the chat composer.
 *
 * The UI never records without an explicit user gesture. Permission states are
 * prompt / granted / denied / no-device / unsupported; denied and no-device
 * carry actionable copy (OS settings path, "connect a microphone"). Audio goes
 * only to the local backend: getUserMedia → 16 kHz mono WAV → /api/speech/transcribe.
 */

import type { MicrophoneState } from './types.js';

export interface MicrophoneController extends MicrophoneState {
    /** Ask the browser/Electron for access (getUserMedia). */
    requestPermission(): Promise<void>;
    /** Re-check permission without prompting (Permissions API where available). */
    refreshPermission(): Promise<void>;
    /** Release the track / MediaStream. */
    stop(): void;
}

export interface UseMicrophoneOptions {
    /** Default false: ask only when the user first presses the mic. */
    readonly autoRequest?: boolean;
    /** Injectable for tests. */
    readonly getUserMedia?: (constraints: MediaStreamConstraints) => Promise<MediaStream>;
}

export function useMicrophone(_options: UseMicrophoneOptions = {}): MicrophoneController {
    throw new Error('TODO(stage2): implement permission states, stream lifecycle and cleanup.');
}

/** Hold-to-talk + keyboard shortcut configuration (accessible, not hover-only). */
export const PUSH_TO_TALK_SHORTCUT = {
    key: 'M',
    code: 'KeyM',
    shift: true,
    mod: true,
} as const;

export const PUSH_TO_TALK_SHORTCUT_LABEL = 'Ctrl/⌘+Shift+M';

export interface PushToTalkOptions {
    /** Converts and posts the recording; resolves to the transcript text. */
    readonly transcribe: (wav: Blob) => Promise<{ readonly text: string }>;
    /** Insert the transcript into the composer (and auto-send when enabled). */
    readonly onTranscript: (text: string) => void;
    /** Recording/transcription failure shown next to the composer. */
    readonly onError?: (error: Error) => void;
    readonly onRecordingChange?: (recording: boolean) => void;
    readonly microphone?: MicrophoneController;
}

export interface PushToTalkController {
    readonly state: MicrophoneState;
    readonly busy: boolean;
    readonly shortcutLabel: string;
    /** Press/hold start; no-op when permission is not granted. */
    start(): Promise<void>;
    /** Release: stop, encode, transcribe, insert. */
    stop(): Promise<void>;
    /** Escape/blur: stop and discard without transcribing. */
    cancel(): void;
}

export function usePushToTalk(_options: PushToTalkOptions): PushToTalkController {
    throw new Error('TODO(stage2): wire hold-to-talk, shortcut, MediaRecorder and transcribe.');
}
