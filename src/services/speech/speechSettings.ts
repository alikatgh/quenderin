import type {
    SpeechSettings,
    SpeechSettingsResponse,
    UpdateSpeechSettingsRequest,
} from './types.js';

/** Fresh install: voice off until the user explicitly opts in. */
export const DEFAULT_SPEECH_SETTINGS: SpeechSettings = {
    voiceEnabled: false,
    modelId: null,
    autoSend: false,
};

export interface SpeechSettingsFileSystem {
    readFile(filePath: string): Promise<string>;
    writeFile(filePath: string, data: string, options: { readonly mode: 0o600 }): Promise<void>;
    rename(from: string, to: string): Promise<void>;
    mkdir(directory: string, options: { readonly recursive: true }): Promise<void>;
    unlink(filePath: string): Promise<void>;
}

export interface SpeechSettingsStoreOptions {
    /** Defaults to ~/.quenderin/speech-settings.json. */
    readonly filePath?: string;
    readonly fs?: SpeechSettingsFileSystem;
    readonly now?: () => number;
}

/**
 * Persisted voice choice. Written atomically (temp file + rename, mode 0600),
 * so a crash never leaves a half-written settings file. Missing/corrupt files
 * mean "voice off, no model" — never a reason to fail app start.
 */
export class SpeechSettingsStore {
    constructor(_options: SpeechSettingsStoreOptions = {}) {
        throw new Error('TODO(stage2): construct the settings store (default path, injectable fs/clock).');
    }

    /** Read settings; a missing or corrupt file yields DEFAULT_SPEECH_SETTINGS. */
    async get(): Promise<SpeechSettingsResponse> {
        throw new Error('TODO(stage2): load and validate speech-settings.json.');
    }

    /** Merge a patch, persist atomically and return the new settings. */
    async update(_patch: UpdateSpeechSettingsRequest): Promise<SpeechSettingsResponse> {
        throw new Error('TODO(stage2): validate, merge and atomically persist the settings patch.');
    }

    /** Forget the saved choice (used by tests / a full reset). */
    async reset(): Promise<SpeechSettingsResponse> {
        throw new Error('TODO(stage2): delete the settings file and return defaults.');
    }
}

/** Validate an unknown JSON value into SpeechSettings, or throw a concrete error. */
export function parseSpeechSettings(_raw: unknown): SpeechSettings {
    throw new Error('TODO(stage2): validate voiceEnabled/modelId/autoSend without accepting unknown keys.');
}
