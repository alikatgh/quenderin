import { SpeechError } from './errors.js';
import { randomUUID } from 'node:crypto';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import type { SpeechSettings, SpeechSettingsResponse, UpdateSpeechSettingsRequest } from './types.js';

export const DEFAULT_SPEECH_SETTINGS: SpeechSettings = {
    voiceEnabled: false, modelId: null, autoSend: false,
};

const defaults = (): SpeechSettingsResponse => ({
    ...DEFAULT_SPEECH_SETTINGS, updatedAt: new Date(0).toISOString(),
});

export interface SpeechSettingsFileSystem {
    readFile(filePath: string): Promise<string>;
    writeFile(filePath: string, data: string, options: { readonly mode: 0o600; readonly flag: 'wx' }): Promise<void>;
    rename(from: string, to: string): Promise<void>;
    mkdir(directory: string, options: { readonly recursive: true; readonly mode: 0o700 }): Promise<void>;
    unlink(filePath: string): Promise<void>;
}

export interface SpeechSettingsStoreOptions {
    readonly filePath?: string;
    readonly fs?: SpeechSettingsFileSystem;
    readonly now?: () => number;
    readonly knownModel?: (modelId: string) => boolean;
}

export function parseSpeechSettingsPatch(raw: unknown): UpdateSpeechSettingsRequest {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Expected speech settings object.');
    for (const [key, value] of Object.entries(raw)) {
        if ((key === 'voiceEnabled' || key === 'autoSend') && typeof value === 'boolean') continue;
        if (key === 'modelId' && (value === null || (typeof value === 'string' && value.length > 0))) continue;
        throw new Error('Invalid speech settings field.');
    }
    return raw;
}

export function parseSpeechSettings(raw: unknown): SpeechSettings {
    const { voiceEnabled, modelId, autoSend } = parseSpeechSettingsPatch(raw);
    if (voiceEnabled === undefined || modelId === undefined || autoSend === undefined || (voiceEnabled && !modelId)) {
        throw new SpeechError('invalid-settings', 400, 'Voice settings must include a model when voice is enabled.');
    }
    return { voiceEnabled, modelId, autoSend };
}

export class SpeechSettingsStore {
    private readonly filePath: string;
    private readonly fs: SpeechSettingsFileSystem;
    private pending = Promise.resolve();

    constructor(private readonly options: SpeechSettingsStoreOptions = {}) {
        this.filePath = options.filePath ?? path.join(os.homedir(), '.quenderin', 'speech-settings.json');
        this.fs = options.fs ?? {
            ...fs, readFile: file => fs.readFile(file, 'utf8'),
            mkdir: async (directory, options) => { await fs.mkdir(directory, options); },
        };
    }

    async get(): Promise<SpeechSettingsResponse> {
        try {
            const { updatedAt, ...data } = JSON.parse(await this.fs.readFile(this.filePath));
            const settings = parseSpeechSettings(data);
            this.assertKnownModel(settings);
            return { ...settings, updatedAt: typeof updatedAt === 'string' ? updatedAt : defaults().updatedAt };
        } catch {
            return defaults();
        }
    }

    update(patch: UpdateSpeechSettingsRequest): Promise<SpeechSettingsResponse> {
        return this.serialize(async () => {
            const { updatedAt: _previous, ...current } = await this.get();
            const settings = parseSpeechSettings({ ...current, ...parseSpeechSettingsPatch(patch) });
            this.assertKnownModel(settings);
            const next = { ...settings, updatedAt: new Date(this.options.now?.() ?? Date.now()).toISOString() };
            const temporary = `${this.filePath}.${randomUUID()}.tmp`;
            await this.fs.mkdir(path.dirname(this.filePath), { recursive: true, mode: 0o700 });
            try {
                await this.fs.writeFile(temporary, JSON.stringify(next) + '\n', { mode: 0o600, flag: 'wx' });
                await this.fs.rename(temporary, this.filePath);
            } finally {
                await this.fs.unlink(temporary).catch(() => {});
            }
            return next;
        });
    }

    reset(): Promise<SpeechSettingsResponse> {
        return this.serialize(async () => {
            await this.fs.unlink(this.filePath).catch(error => {
                if (error.code !== 'ENOENT') throw error;
            });
            return defaults();
        });
    }

    private assertKnownModel(settings: SpeechSettings): void {
        if (settings.modelId && this.options.knownModel && !this.options.knownModel(settings.modelId)) {
            throw new Error('Unknown speech model.');
        }
    }

    private serialize<T>(operation: () => Promise<T>): Promise<T> {
        const work = this.pending.then(operation);
        this.pending = work.then(() => {}, () => {});
        return work;
    }
}
