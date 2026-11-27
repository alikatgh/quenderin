/** A–F plus "none" for an unmeasured language (Handy shows "?"). */
export type SpeechGradeLetter = 'A' | 'B' | 'C' | 'D' | 'F' | 'none';

export interface SpeechAccuracyGrade {
    readonly letter: SpeechGradeLetter;
    /** "A+", "B−", "—" (unsupported), "?" (unmeasured). */
    readonly label: string;
}

export type SpeechSpeedLevel = 0 | 1 | 2 | 3 | 4;

/** Whether the pinned runtime (shared/speech-runtime.json) can load this model. */
export type SpeechEngineCompatibility = 'supported' | 'needs-newer-engine';

/** One catalog row as the picker renders it, with grades computed server-side. */
export interface SpeechModelSummary {
    readonly model: import('@handy-computer/models').CatalogModel;
    /** English accuracy, or "none" when Handy has no English measurement. */
    readonly englishGrade: SpeechAccuracyGrade;
    /** Seconds after a 30-second dictation on the benchmark GPU, when measured. */
    readonly waitSeconds: number | null;
    readonly speedLevel: SpeechSpeedLevel;
    readonly engine: {
        readonly pinnedVersion: string;
        readonly requiredVersion: string | null;
        readonly compatibility: SpeechEngineCompatibility;
    };
    readonly installed: boolean;
    /** Bytes on disk when installed, from the catalog's exact size. */
    readonly installedBytes: number | null;
}

export interface SpeechModelListResponse {
    readonly runtimeEngineVersion: string;
    readonly recommendedModelId: string | null;
    readonly accurateModelId: string | null;
    readonly methodology: import('@handy-computer/models').Methodology;
    readonly models: readonly SpeechModelSummary[];
}

/** Download state machine: idle → queued → downloading ⇄ paused → verifying → installed. */
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
    | 'http-size'
    | 'unsupported-engine'
    | 'permission'
    | 'cancelled'
    | 'unknown';

export interface SpeechDownloadError {
    readonly kind: SpeechDownloadErrorKind;
    readonly message: string;
    /** HTTP status when the failure came from the server. */
    readonly status: number | null;
}

export interface SpeechDownloadSnapshot {
    readonly modelId: string;
    readonly phase: SpeechDownloadPhase;
    readonly downloadedBytes: number;
    readonly totalBytes: number;
    /** 0–100; 0 when the total is unknown. */
    readonly percent: number;
    readonly bytesPerSecond: number | null;
    readonly etaSeconds: number | null;
    readonly error: SpeechDownloadError | null;
    /** ISO-8601, when the snapshot last changed. */
    readonly updatedAt: string;
}

export interface SpeechDownloadEvent {
    readonly type: 'speech_download_progress';
    readonly snapshot: SpeechDownloadSnapshot;
}

export interface SpeechSettings {
    /** false when the user chose "Skip — I'll type". */
    readonly voiceEnabled: boolean;
    /** Selected catalog id, even while voice is disabled; null before any choice. */
    readonly modelId: string | null;
    /** Insert-and-send instead of insert-only. */
    readonly autoSend: boolean;
}

export interface SpeechSettingsResponse extends SpeechSettings {
    readonly updatedAt: string;
}

export interface StartSpeechDownloadRequest {
    readonly modelId: string;
}

export interface UpdateSpeechSettingsRequest {
    readonly voiceEnabled?: boolean;
    readonly modelId?: string | null;
    readonly autoSend?: boolean;
}

export interface SpeechTranscriptionSegment {
    readonly startMs: number;
    readonly endMs: number;
    readonly text: string;
}

export interface SpeechTranscriptionResponse {
    readonly text: string;
    readonly rawText: string;
    readonly language: string;
    readonly backend: string;
    readonly modelId: string;
    readonly durationMs: number;
    readonly truncated: boolean;
    readonly segments: readonly SpeechTranscriptionSegment[];
    /** Echoed so the composer can decide whether to send immediately. */
    readonly autoSend: boolean;
}

export interface SpeechApiErrorBody {
    readonly error: string;
    readonly code: string;
}
