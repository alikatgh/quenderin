import { Mic } from 'lucide-react';
import { VoiceInputButton } from './VoiceInputButton.js';
import { speechApi } from '../lib/speech/api.js';
import type { SpeechTranscriptionResponse } from '../lib/speech/types.js';

export interface VoiceComposerOptions {
    modelId?: string;
    onSettings: () => void;
    blocked?: boolean;
}

export function VoiceComposerControl({ voice, disabled, onTranscript }: {
    voice?: VoiceComposerOptions;
    disabled?: boolean;
    onTranscript: (result: Pick<SpeechTranscriptionResponse, 'text' | 'autoSend'>) => void;
}) {
    if (!voice) return null;
    const modelId = voice.modelId;
    if (!modelId) {
        return <button type="button" onClick={voice.onSettings} disabled={disabled}
            aria-label="Set up voice dictation in Settings" title="Set up voice dictation in Settings"
            className="rounded-lg p-2 text-zinc-500 hover:bg-zinc-100 focus-visible:outline focus-visible:outline-2 focus-visible:outline-qteal-500 dark:text-zinc-400 dark:hover:bg-zinc-800">
            <Mic aria-hidden="true" className="size-4" />
        </button>;
    }
    return <VoiceInputButton key={modelId} disabled={disabled || voice.blocked} onTranscript={onTranscript}
        transcribe={(wav, signal) => speechApi.transcribe(wav, { modelId, signal })} />;
}

export function appendTranscript(draft: string, transcript: string): string {
    return draft.trim() ? `${draft.trimEnd()} ${transcript.trim()}` : transcript.trim();
}
