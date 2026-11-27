import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WelcomeWizard } from '../src/App.js';
import { VoiceModelStep } from '../src/components/onboarding/VoiceModelStep.js';
import { VoiceSettingsSection } from '../src/components/settings/VoiceSettingsSection.js';
import { useSpeechDownload } from '../src/lib/speech/useSpeechDownload.js';
import type { SpeechApi } from '../src/lib/speech/api.js';
import type { SpeechDownloadErrorKind, SpeechDownloadSnapshot } from '../src/lib/speech/types.js';
import { accurate, catalogFixture, recommended, snapshot, speechFixture } from './speechFixtures.js';

afterEach(() => { cleanup(); vi.useRealTimers(); vi.unstubAllGlobals(); });
const showAll = () => fireEvent.click(screen.getByRole('button', { name: 'Show all 29 models' }));

describe('Handy voice model step', () => {
    it('renders optional setup with measured picks and starts the requested model in the background', async () => {
        const speech = speechFixture();
        const finish = vi.fn();
        const { rerender } = render(<VoiceModelStep speech={speech} onFinish={finish} />);
        expect(screen.getByText('Optional')).toBeTruthy();
        expect(screen.getByRole('heading', { name: 'Talk to your local model by voice' })).toBeTruthy();
        expect(screen.getByRole('radio', { name: /Recommended.*Parakeet Unified English 0.6B.*697 MB/ })).toBeTruthy();
        expect(screen.getByRole('radio', { name: /More accurate.*Qwen3-ASR 1.7B.*2.0 GB/ })).toBeTruthy();
        expect(screen.getByText('Downloads while you finish setup')).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: 'Download 697 MB' }));
        await waitFor(() => expect(speech.updateSettings).toHaveBeenCalledWith({ modelId: recommended, voiceEnabled: true }));
        expect(speech.downloads.run).toHaveBeenCalledWith('start', recommended);
        rerender(<VoiceModelStep speech={{
            ...speech, settings: { ...speech.settings!, modelId: recommended, voiceEnabled: true },
            downloads: { ...speech.downloads, snapshots: { [recommended]: snapshot('downloading') } },
        }} onFinish={finish} />);
        fireEvent.click(screen.getByRole('button', { name: 'Finish setup' }));
        expect(finish).toHaveBeenCalledOnce();
        expect(speech.downloads.run).toHaveBeenCalledTimes(1);
    });

    it('derives its count and expands, searches and closes the full list with the keyboard', () => {
        const speech = speechFixture();
        const { rerender } = render(<VoiceModelStep speech={speech} onFinish={vi.fn()} />);
        showAll();
        expect(screen.getByRole('columnheader', { name: 'EN' })).toBeTruthy();
        expect(screen.getByRole('columnheader', { name: 'SPEED' })).toBeTruthy();
        expect(screen.getByRole('columnheader', { name: 'SIZE' })).toBeTruthy();
        const modelRows = within(screen.getByRole('table')).getAllByRole('row').slice(1);
        expect(modelRows).toHaveLength(29);
        modelRows.forEach((row, index) => expect(row.textContent).toContain(`License ${catalogFixture.models[index].model.license}`));
        const search = screen.getByRole('searchbox', { name: 'Search models' });
        expect(document.activeElement).toBe(search);
        fireEvent.change(search, { target: { value: 'qwen 1.7b' } });
        expect(screen.getAllByRole('row')).toHaveLength(2);
        fireEvent.keyDown(search, { key: 'ArrowDown' });
        expect(document.activeElement).toBe(screen.getByRole('button', { name: /Qwen3-ASR 1.7B/ }));
        fireEvent.keyDown(document.activeElement!, { key: 'Escape' });
        expect((search as HTMLInputElement).value).toBe('');
        fireEvent.keyDown(document.activeElement!, { key: 'Escape' });
        expect(screen.queryByRole('table')).toBeNull();
        const more = screen.getByRole('button', { name: 'Show all 29 models' });
        expect(document.activeElement).toBe(more);
        fireEvent.keyDown(more, { key: 'q' });
        expect((screen.getByRole('searchbox') as HTMLInputElement).value).toBe('q');
        fireEvent.click(screen.getByRole('button', { name: 'Hide all models' }));
        rerender(<VoiceModelStep speech={{ ...speech, catalog: { ...catalogFixture, models: catalogFixture.models.slice(0, 4) } }} onFinish={vi.fn()} />);
        expect(screen.getByRole('button', { name: 'Show all 4 models' })).toBeTruthy();
    });

    it('combines both capability filters with model text search', () => {
        render(<VoiceModelStep speech={speechFixture()} onFinish={vi.fn()} />);
        showAll();
        const table = within(screen.getByRole('table'));
        fireEvent.click(screen.getByRole('checkbox', { name: 'Live preview' }));
        const streaming = catalogFixture.models.filter(row => row.model.capabilities.streaming);
        expect(table.getAllByRole('row')).toHaveLength(streaming.length + 1);
        fireEvent.click(screen.getByRole('checkbox', { name: 'Translates' }));
        const both = streaming.filter(row => row.model.capabilities.translate);
        expect(table.getAllByRole('row')).toHaveLength(both.length + 1);
        fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'no such model' } });
        expect(screen.getByText('No models match your search.')).toBeTruthy();
        expect(table.getAllByRole('row')).toHaveLength(1);
    });

    it('shows blocked models and prevents their download', () => {
        const models = catalogFixture.models.map(row => row.model.id === accurate
            ? { ...row, engine: { ...row.engine, compatibility: 'needs-newer-engine' as const, requiredVersion: '9.0.0' } }
            : row);
        const speech = speechFixture({ catalog: { ...catalogFixture, models } });
        render(<VoiceModelStep speech={speech} onFinish={vi.fn()} />);
        fireEvent.click(screen.getByRole('radio', { name: /More accurate/ }));
        expect(screen.getByText('Needs newer speech engine')).toBeTruthy();
        expect((screen.getByRole('button', { name: 'Download 2.0 GB' }) as HTMLButtonElement).disabled).toBe(true);
        expect(speech.downloads.run).not.toHaveBeenCalled();
    });

    it('changes the selected model and visibly exposes pause, resume, cancel and retry', async () => {
        const speech = speechFixture();
        const finish = vi.fn();
        const { rerender } = render(<VoiceModelStep speech={speech} onFinish={finish} />);
        fireEvent.click(screen.getByRole('radio', { name: /More accurate/ }));
        fireEvent.click(screen.getByRole('button', { name: 'Download 2.0 GB' }));
        await waitFor(() => expect(speech.downloads.run).toHaveBeenLastCalledWith('start', accurate));
        await waitFor(() => expect((screen.getByRole('radio', { name: /More accurate/ }) as HTMLInputElement).disabled).toBe(false));
        for (const [phase, button, command] of [
            ['downloading', 'Pause', 'pause'],
            ['paused', 'Resume', 'resume'],
            ['error', 'Retry', 'retry'],
            ['paused', 'Cancel download', 'cancel'],
        ] as const) {
            const state = snapshot(phase, { modelId: accurate });
            rerender(<VoiceModelStep speech={{
                ...speech, downloads: { ...speech.downloads, snapshots: { [accurate]: state } },
            }} onFinish={finish} />);
            if (phase === 'downloading') {
                const progress = screen.getByRole('progressbar', { name: /Qwen3-ASR/ }) as HTMLProgressElement;
                expect(progress.value).toBe(14);
                expect(progress.max).toBe(100);
                expect(screen.getByText(/14% · 100 MB of /)).toBeTruthy();
            }
            fireEvent.click(screen.getByRole('button', { name: button }));
            await waitFor(() => expect(speech.downloads.run).toHaveBeenLastCalledWith(command, accurate));
            await waitFor(() => expect((screen.getByRole('button', { name: button }) as HTMLButtonElement).disabled).toBe(false));
        }
    });

    it.each([
        ['network', 'Check your connection.'], ['disk-full', 'Free disk space.'],
        ['checksum-mismatch', 'File verification failed.'], ['http-404', 'Pinned artifact unavailable.'],
        ['http-416', 'Could not resume.'],
    ] as [SpeechDownloadErrorKind, string][])('announces %s errors and keeps Skip available', async (kind, message) => {
        const finish = vi.fn();
        const speech = speechFixture();
        render(<VoiceModelStep speech={{
            ...speech,
            settings: { ...speech.settings!, voiceEnabled: true, modelId: recommended },
            downloads: { ...speech.downloads, snapshots: { [recommended]: snapshot('error', { error: { kind, message, status: null } }) } },
        }} onFinish={finish} />);
        expect(screen.getByRole('alert').textContent).toBe(message);
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        await waitFor(() => expect(finish).toHaveBeenCalledOnce());
        expect(speech.updateSettings).toHaveBeenCalledWith({ voiceEnabled: false });
    });

    it('finishes immediately on Skip when loaded picker already has voice disabled even if backend drops', async () => {
        const finish = vi.fn();
        const speech = speechFixture();
        speech.updateSettings.mockRejectedValue(new Error('offline'));
        render(<VoiceModelStep speech={speech} onFinish={finish} />);
        expect(screen.getByRole('radio', { name: /Recommended/ })).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        await waitFor(() => expect(finish).toHaveBeenCalledOnce());
        expect(speech.updateSettings).not.toHaveBeenCalled();
    });

    it('keeps error and retry visible on Skip when loaded picker has voice enabled and PUT fails', async () => {
        const finish = vi.fn();
        const speech = speechFixture({
            settings: { voiceEnabled: true, modelId: recommended, autoSend: false, updatedAt: '2026-11-27T00:00:00.000Z' },
        });
        speech.updateSettings.mockRejectedValueOnce(new Error('backend down')).mockResolvedValueOnce(undefined);
        render(<VoiceModelStep speech={speech} onFinish={finish} />);
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        expect((await screen.findByRole('alert')).textContent).toMatch(/Could not turn off voice/);
        expect(finish).not.toHaveBeenCalled();
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        await waitFor(() => expect(finish).toHaveBeenCalledOnce());
    });

    it('keeps voice optional when the service cannot be reached', async () => {
        const finish = vi.fn();
        const speech = speechFixture({ catalog: null, loadError: 'Service unavailable.' });
        speech.updateSettings.mockRejectedValueOnce(new Error('offline'));
        render(<VoiceModelStep speech={speech} onFinish={finish} />);
        expect(screen.getByRole('alert').textContent).toBe('Service unavailable.');
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        await waitFor(() => expect(finish).toHaveBeenCalledOnce());
    });

    it('reconciles a missed final installed WebSocket event on a healthy connection while a download is active', async () => {
        vi.useFakeTimers();
        const downloading = snapshot('downloading', { updatedAt: '2026-11-27T00:00:01.000Z' });
        const installed = snapshot('installed', {
            downloadedBytes: downloading.totalBytes, percent: 100, updatedAt: '2026-11-27T00:00:02.000Z',
        });
        const listDownloads = vi.fn<SpeechApi['listDownloads']>()
            .mockResolvedValueOnce([downloading])
            .mockResolvedValueOnce([installed]);
        const api = { listDownloads } as unknown as SpeechApi;

        function Probe({ events }: { events: Readonly<Record<string, SpeechDownloadSnapshot>> }) {
            const { snapshots } = useSpeechDownload(true, events, api);
            return <output>{snapshots[recommended]?.phase ?? 'none'}</output>;
        }

        render(<Probe events={{ [recommended]: downloading }} />);
        await act(async () => { await Promise.resolve(); });
        expect(screen.getByRole('status').textContent).toBe('downloading');

        // Final WS frame is dropped; bounded reconciliation polls authoritative REST snapshot.
        await act(async () => { await vi.advanceTimersByTimeAsync(2500); });
        expect(listDownloads).toHaveBeenCalledTimes(2);
        expect(screen.getByRole('status').textContent).toBe('installed');

        // Once no job is active on a connected socket, polling stops.
        await act(async () => { await vi.advanceTimersByTimeAsync(5000); });
        expect(listDownloads).toHaveBeenCalledTimes(2);
    });
});

describe('Quenderin voice setup bindings', () => {
    it('kicks off the selected local LLM before voice setup and completes via Skip', async () => {
        const speech = speechFixture();
        const finish = vi.fn();
        const fetch = vi.fn(async (url: string) => new Response(JSON.stringify(url.endsWith('catalog')
            ? { catalog: [
                { id: 'llm-a', label: 'Local A', sizeLabel: '800 MB', isDownloaded: false, runtimeCompatible: true },
                { id: 'llm-b', label: 'Local B', sizeLabel: '600 MB', isDownloaded: false, runtimeCompatible: true },
            ], activeModelId: 'llm-a' }
            : { modelId: 'llm-b' }), { headers: { 'Content-Type': 'application/json' } }));
        vi.stubGlobal('fetch', fetch);
        render(<WelcomeWizard speech={speech} downloadModelId={null} downloadProgress={0} recommendedModelId="llm-a"
            onDismiss={finish} onImages={vi.fn()} onVision={vi.fn()} />);
        expect(screen.getByRole('progressbar', { name: 'Setup step' }).getAttribute('aria-valuemax')).toBe('2');
        fireEvent.change(await screen.findByRole('combobox', { name: 'Chat model' }), { target: { value: 'llm-b' } });
        fireEvent.click(screen.getByRole('button', { name: 'Download chat model' }));
        const continueSetup = await screen.findByRole('button', { name: 'Continue while downloading' });
        expect(fetch).toHaveBeenCalledWith('/api/models/download', expect.objectContaining({
            method: 'POST', body: JSON.stringify({ modelId: 'llm-b', activate: true }),
        }));
        fireEvent.click(continueSetup);
        expect(screen.getByRole('heading', { name: 'Talk to your local model by voice' })).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        await waitFor(() => expect(finish).toHaveBeenCalledOnce());
    });

    it('changes auto-send and confirms removing the installed model from Settings', async () => {
        const speech = speechFixture();
        const models = catalogFixture.models.map(row => row.model.id === recommended ? { ...row, installed: true } : row);
        render(<VoiceSettingsSection speech={{
            ...speech, catalog: { ...catalogFixture, models }, settings: { ...speech.settings!, modelId: recommended, voiceEnabled: true },
        }} />);
        fireEvent.click(screen.getByRole('checkbox', { name: 'Automatically send transcript' }));
        await waitFor(() => expect(speech.updateSettings).toHaveBeenCalledWith({ autoSend: true }));
        fireEvent.click(screen.getByRole('button', { name: 'Remove model' }));
        expect(speech.downloads.run).not.toHaveBeenCalled();
        fireEvent.click(screen.getByRole('button', { name: 'Confirm removal' }));
        await waitFor(() => expect(speech.removeModel).toHaveBeenCalledWith(recommended));
        expect(screen.getByText('Voice credits and licenses')).toBeTruthy();
    });
});
