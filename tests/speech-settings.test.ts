import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_SPEECH_SETTINGS, SpeechSettingsStore } from '../src/services/speech/speechSettings.js';

describe('speech settings persistence', () => {
    let dir: string;
    let filePath: string;
    let store: SpeechSettingsStore;
    beforeEach(async () => {
        dir = await fs.mkdtemp(path.join(os.tmpdir(), 'quenderin-speech-settings-test-'));
        filePath = path.join(dir, 'speech-settings.json');
        store = new SpeechSettingsStore({ filePath, knownModel: id => id === 'fixture' });
    });
    afterEach(async () => { await fs.rm(dir, { recursive: true, force: true }); });

    it('defaults to typing on a fresh install, corrupt file or obsolete selection', async () => {
        expect(await store.get()).toMatchObject(DEFAULT_SPEECH_SETTINGS);
        for (const body of ['{', 'null', JSON.stringify({ voiceEnabled: true, modelId: 'unknown', autoSend: false })]) {
            await fs.writeFile(filePath, body);
            expect(await store.get()).toMatchObject(DEFAULT_SPEECH_SETTINGS);
        }
    });

    it('serializes concurrent updates, preserves explicit selection and reloads', async () => {
        await Promise.all([
            store.update({ voiceEnabled: true, modelId: 'fixture' }),
            store.update({ autoSend: true }),
        ]);
        const reopened = new SpeechSettingsStore({ filePath });
        expect(await reopened.get()).toMatchObject({ modelId: 'fixture', voiceEnabled: true, autoSend: true });
        await reopened.update({ voiceEnabled: false });
        expect(await store.get()).toMatchObject({ modelId: 'fixture', voiceEnabled: false });
        expect(await fs.readdir(dir)).toEqual(['speech-settings.json']);
        if (process.platform !== 'win32') expect((await fs.stat(filePath)).mode & 0o777).toBe(0o600);
    });

    it('cleans up the temporary file if a write cannot be finalized', async () => {
        const rename = vi.fn(async () => { throw Error('rename failed'); });
        store = new SpeechSettingsStore({
            filePath,
            fs: {
                readFile: file => fs.readFile(file, 'utf8'), writeFile: fs.writeFile,
                mkdir: async (directory, options) => { await fs.mkdir(directory, options); },
                rename, unlink: fs.unlink,
            },
        });
        await fs.writeFile(filePath, JSON.stringify(DEFAULT_SPEECH_SETTINGS));
        await expect(store.update({ autoSend: true })).rejects.toThrow('rename failed');
        expect(rename.mock.calls.flat()).toContain(filePath);
        expect(await store.get()).toMatchObject(DEFAULT_SPEECH_SETTINGS);
        expect(await fs.readdir(dir)).toEqual(['speech-settings.json']);
    });

    it.each([{ unknown: true }, { voiceEnabled: 'yes' }, { voiceEnabled: true }, { modelId: 'wrong' }, { modelId: 2 }])(
        'rejects invalid settings (%j)', async patch => {
            await expect(store.update(patch as Parameters<typeof store.update>[0])).rejects.toThrow();
            expect(await store.get()).toMatchObject(DEFAULT_SPEECH_SETTINGS);
        },
    );

    it('resets the persisted choice and safely repeats reset', async () => {
        await store.update({ voiceEnabled: true, modelId: 'fixture' });
        expect(await store.reset()).toMatchObject(DEFAULT_SPEECH_SETTINGS);
        expect(await store.reset()).toMatchObject(DEFAULT_SPEECH_SETTINGS);
        expect(await fs.readdir(dir)).toEqual([]);
    });
});
