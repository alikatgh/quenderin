/**
 * UI-side speech types. The catalog entry shape is imported from the one
 * canonical declaration in shared/, so the picker and the backend loader can
 * never disagree about what a Handy model is.
 */

export type {
    HandySpeechCatalog,
    HandySpeechModel,
    SpeechAccuracyCell,
    SpeechMethodology,
    SpeechModelCapabilities,
    SpeechModelFile,
    SpeechModelResults,
} from '../../../../shared/handy-speech-types.js';

import type {
    HandySpeechModel,
    SpeechMethodology,
} from '../../../../shared/handy-speech-types.js';

export type SpeechGradeLetter = 'A' | 'B' | 'C' | 'D' | 'F' | 'none';

export interface SpeechAccuracyGrade {
    readonly letter: SpeechGradeLetter;
    /** "A+", "B−", "—" (unsupported), "?" (unmeasured). */
    readonly label: string;
}

export type SpeechSpeedLevel = 0 | 1 | 2 | 3 | 4;

export type SpeechEngineCompatibility = 'supported' | 'needs-newer-engine';

/** One row from GET /api/speech/models. */
export interface SpeechModelSummary {
    readonly model: HandySpeechModel;
    readonly englishGrade: SpeechAccuracyGrade;
    readonly waitSeconds: number | null;
    readonly speedLevel: SpeechSpeedLevel;
    readonly engine: {
        readonly pinnedVersion: string;
        readonly requiredVersion: string;
        readonly compatibility: SpeechEngineCompatibility;
    };
    readonly installed: boolean;
    readonly installedBytes: number | null;
}

export interface SpeechModelListResponse {
    readonly runtimeEngineVersion: string;
    readonly recommendedModelId: string;
    readonly accurateModelId: string;
    readonly methodology: SpeechMethodology;
    readonly models: readonly SpeechModelSummary[];
}

export type SpeechDownloadPhase =
    | 'idle'
    | 'queued'
    | 'downloading'
    | 'paused'
    | 'verifying'
    | 'installed'
    | 'error';

export type SpeechDownloadErrorKind =
    | 'network'
    | 'disk-full'
    | 'checksum-mismatch'
    | 'http-404'
    | 'http-416'
    | 'unsupported-engine'
    | 'permission'
    | 'cancelled'
    | 'unknown';

export interface SpeechDownloadError {
    readonly kind: SpeechDownloadErrorKind;
    readonly message: string;
    readonly status: number | null;
}

export interface SpeechDownloadSnapshot {
    readonly modelId: string;
    readonly phase: SpeechDownloadPhase;
    readonly downloadedBytes: number;
    readonly totalBytes: number;
    readonly percent: number;
    readonly bytesPerSecond: number | null;
    readonly etaSeconds: number | null;
    readonly error: SpeechDownloadError | null;
    readonly updatedAt: string;
}

export interface SpeechDownloadEvent {
    readonly type: 'speech_download_progress';
    readonly snapshot: SpeechDownloadSnapshot;
}

export interface SpeechSettings {
    readonly voiceEnabled: boolean;
    readonly modelId: string | null;
    readonly autoSend: boolean;
}

export interface SpeechSettingsResponse extends SpeechSettings {
    readonly updatedAt: string;
}

export interface UpdateSpeechSettingsRequest {
    readonly voiceEnabled?: boolean;
    readonly modelId?: string | null;
    readonly autoSend?: boolean;
}

/** Mic permission state for the composer's push-to-talk button. */
export type MicrophonePermission = 'prompt' | 'granted' | 'denied' | 'no-device' | 'unsupported';

export interface MicrophoneState {
    readonly permission: MicrophonePermission;
    readonly error: string | null;
    readonly recording: boolean;
}

export type SpeechTranscriptionResponse = {
    readonly text: string;
    readonly rawText: string;
    readonly language: string;
    readonly backend: string;
    readonly modelId: string;
    readonly durationMs: number;
    readonly truncated: boolean;
    readonly segments: readonly { readonly startMs: number; readonly endMs: number; readonly text: string }[];
    readonly autoSend: boolean;
};

export interface SpeechApiErrorBody {
    readonly error: string;
    readonly code: string;
}
