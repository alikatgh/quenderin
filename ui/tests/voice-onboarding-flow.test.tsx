import { useLayoutEffect, useRef, useState } from 'react';
import { catalog, CURATED_MODELS, modelFile } from '@handy-computer/models';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import App, { WelcomeWizard } from '../src/App.js';
import { useSpeechSetup } from '../src/lib/speech/useSpeechSetup.js';
import type {
    SpeechDownloadSnapshot, SpeechModelListResponse, SpeechSettingsResponse, UpdateSpeechSettingsRequest,
} from '../src/lib/speech/types.js';

const recommendedId = 'parakeet-unified-en-0.6b';
const accurateId = 'Qwen3-ASR-1.7B';
const chatCatalog = {
    activeModelId: 'current-chat',
    catalog: [
        { id: 'current-chat', label: 'Current chat', sizeLabel: '1 GB', isDownloaded: true, runtimeCompatible: true },
        { id: 'installed-chat', label: 'Installed chat', sizeLabel: '2 GB', isDownloaded: true, runtimeCompatible: true },
        { id: 'new-chat', label: 'New chat', sizeLabel: '3 GB', isDownloaded: false, runtimeCompatible: true },
    ],
};
const voiceCatalog: SpeechModelListResponse = {
    recommendedModelId: recommendedId, accurateModelId: accurateId, runtimeEngineVersion: '0.4.1',
    methodology: catalog.methodology,
    models: CURATED_MODELS.map(model => ({
        model, englishGrade: { letter: 'none', label: '?' }, waitSeconds: null, speedLevel: 0,
        engine: { pinnedVersion: '0.4.1', requiredVersion: model.minEngine ?? null, compatibility: 'supported' },
        installed: false, installedBytes: null,
    })),
};
const noEvents = {};

function Wizard() {
    const [open, setOpen] = useState(true);
    const speech = useSpeechSetup(true, noEvents);
    return open ? <WelcomeWizard speech={speech} onDismiss={() => setOpen(false)} onImages={() => {}} onVision={() => {}}
        downloadModelId={null} downloadProgress={0} /> : <p>Setup complete</p>;
}

function mockDashboard(initial: SpeechSettingsResponse) {
    let settings = initial;
    let download: SpeechDownloadSnapshot | undefined;
    const writes: { method: string; url: string; body: unknown }[] = [];
    const response = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });
    vi.stubGlobal('fetch', vi.fn(async (url: string, { method = 'GET', body }: RequestInit = {}) => {
        if (method !== 'GET') writes.push({ method, url, body: typeof body === 'string' ? JSON.parse(body) : null });
        if (url === '/api/models/catalog') return response(chatCatalog);
        if (url === '/api/models/switch' || url === '/api/models/download') return response({});
        if (url === '/api/speech/models') return response(voiceCatalog);
        if (url === '/api/speech/settings') {
            if (method === 'PUT') settings = { ...settings, ...JSON.parse(String(body)) as UpdateSpeechSettingsRequest };
            return response(settings);
        }
        if (url === '/api/speech/downloads') {
            if (method === 'GET') return response(download ? [download] : []);
            const { modelId } = JSON.parse(String(body));
            const row = voiceCatalog.models.find(entry => entry.model.id === modelId);
            if (!row) throw Error('Unexpected voice model id in test request.');
            const totalBytes = modelFile(row.model).size;
            download = {
                modelId, phase: 'downloading', downloadedBytes: Math.floor(totalBytes / 4), totalBytes, percent: 25,
                bytesPerSecond: null, etaSeconds: null, error: null, updatedAt: settings.updatedAt,
            };
            return response(download, 202);
        }
        if (url.startsWith('/api/speech/downloads/')) {
            return download?.modelId === decodeURIComponent(url.split('/').at(-1)!) ? response(download) :
                response({ error: 'No download.', code: 'download-not-found' }, 404);
        }
        throw Error(`Unexpected dashboard request in test: ${url}`);
    }));
    return { writes, settings: () => settings };
}

async function chooseChat(modelId: string) {
    expect(screen.getByRole('progressbar', { name: 'Setup step' }).getAttribute('aria-valuenow')).toBe('1');
    fireEvent.change(await screen.findByRole('combobox', { name: 'Chat model' }), { target: { value: modelId } });
}

async function expectVoiceStep() {
    await screen.findByRole('heading', { name: 'Talk to your local model by voice' });
    expect(screen.getByRole('progressbar', { name: 'Setup step' }).getAttribute('aria-valuenow')).toBe('2');
    expect(screen.getByText('Optional')).toBeTruthy();
    expect(screen.getByRole('radio', { name: /Recommended.*Parakeet Unified English/ })).toBeTruthy();
    expect(screen.getByRole('radio', { name: /More accurate.*Qwen3-ASR 1.7B/ })).toBeTruthy();
}

afterEach(() => { cleanup(); vi.useRealTimers(); vi.unstubAllGlobals(); });

it('switches to an installed chat model and persists Skip on the optional voice step', async () => {
    const dashboard = mockDashboard({ voiceEnabled: true, modelId: recommendedId, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' });
    render(<Wizard />);
    await chooseChat('installed-chat');
    fireEvent.click(screen.getByRole('button', { name: 'Next: Voice' }));
    await expectVoiceStep();
    expect(screen.getByRole('button', { name: `Show all ${CURATED_MODELS.length} models` })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));

    await screen.findByText('Setup complete');
    expect(dashboard.writes).toEqual([
        { method: 'POST', url: '/api/models/switch', body: { modelId: 'installed-chat' } },
        { method: 'PUT', url: '/api/speech/settings', body: { voiceEnabled: false } },
    ]);
    expect(dashboard.settings()).toMatchObject({ voiceEnabled: false, modelId: recommendedId });
});

it('finishes setup while the separately chosen voice model is downloading', async () => {
    const dashboard = mockDashboard({ voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' });
    render(<Wizard />);
    await chooseChat('new-chat');
    fireEvent.click(screen.getByRole('button', { name: 'Download chat model' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Continue while downloading' }));
    await expectVoiceStep();
    expect(screen.getByText('Downloads while you finish setup')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Download 697 MB' })).toBeTruthy();

    fireEvent.click(screen.getByRole('radio', { name: /More accurate.*Qwen3-ASR 1.7B/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Download 2.0 GB' }));
    const progress = await screen.findByRole<HTMLProgressElement>('progressbar', { name: /Qwen3-ASR 1.7B download progress/ });
    expect(progress.value).toBe(25);
    fireEvent.click(await screen.findByRole('button', { name: 'Finish setup' }));

    await screen.findByText('Setup complete');
    expect(dashboard.writes).toEqual([
        { method: 'POST', url: '/api/models/download', body: { modelId: 'new-chat', activate: true } },
        { method: 'POST', url: '/api/speech/downloads', body: { modelId: accurateId } },
        { method: 'PUT', url: '/api/speech/settings', body: { modelId: accurateId, voiceEnabled: true } },
    ]);
    expect(dashboard.settings()).toMatchObject({ modelId: accurateId, voiceEnabled: true, autoSend: false });
});

it('surfaces a 409 busy chat-model download error without advancing to step 2', async () => {
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
        if (url === '/api/models/catalog') return new Response(JSON.stringify(chatCatalog), { status: 200 });
        if (url === '/api/models/download') {
            return new Response(JSON.stringify({
                error: 'Another chat model download is already in progress.',
                code: 'MODEL_DOWNLOAD_BUSY',
                activeDownloadModelId: 'other-chat',
            }), { status: 409 });
        }
        if (url === '/api/speech/models') return new Response(JSON.stringify(voiceCatalog), { status: 200 });
        if (url === '/api/speech/settings') return new Response(JSON.stringify({ voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' }), { status: 200 });
        if (url === '/api/speech/downloads') return new Response('[]', { status: 200 });
        return new Response('{}', { status: 404 });
    }));
    render(<Wizard />);
    await chooseChat('new-chat');
    fireEvent.click(screen.getByRole('button', { name: 'Next: Voice' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/already in progress/);
    expect(screen.getByRole('progressbar', { name: 'Setup step' }).getAttribute('aria-valuenow')).toBe('1');
});

it('keeps background dashboard inert and traps forward and backward Tab on step 2 entry', async () => {
    if (!HTMLElement.prototype.scrollTo) HTMLElement.prototype.scrollTo = () => {};
    if (!HTMLElement.prototype.scrollIntoView) HTMLElement.prototype.scrollIntoView = () => {};
    const storage = new Map<string, string>([['quenderin_disclaimer_accepted', 'true']]);
    vi.stubGlobal('localStorage', {
        getItem: (key: string) => storage.get(key) ?? null,
        setItem: (key: string, value: string) => { storage.set(key, value); },
        removeItem: (key: string) => { storage.delete(key); },
        clear: () => storage.clear(),
    });
    vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
    class StubSocket {
        static OPEN = 1;
        readyState = 1;
        send = vi.fn();
        close = vi.fn();
    }
    vi.stubGlobal('WebSocket', StubSocket);
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url === '/api/models/catalog') return new Response(JSON.stringify(chatCatalog), { status: 200 });
        if (url === '/api/models/switch') return new Response('{}', { status: 200 });
        if (url === '/api/speech/models') return new Response(JSON.stringify(voiceCatalog), { status: 200 });
        if (url === '/api/speech/settings') return new Response(JSON.stringify({ voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' }), { status: 200 });
        if (url === '/api/speech/downloads' || url.startsWith('/api/speech/downloads/')) return new Response(url.endsWith('/downloads') ? '[]' : '{}', { status: url.endsWith('/downloads') ? 200 : 404 });
        if (url === '/health') return new Response(JSON.stringify({ activeModel: 'Current chat' }), { status: 200 });
        if (url === '/ready') return new Response(JSON.stringify({ ready: true, stage: 'ready' }), { status: 200 });
        return new Response(JSON.stringify({ sessions: [] }), { status: 200 });
    }));

    const { container } = render(<App />);
    const dialog = await screen.findByRole('dialog', { name: 'Welcome Setup Wizard' });
    const inertBackdrop = container.querySelector('[inert]');
    expect(inertBackdrop).toBeTruthy();
    expect(inertBackdrop?.getAttribute('aria-hidden')).toBe('true');

    await chooseChat('installed-chat');
    fireEvent.click(screen.getByRole('button', { name: 'Next: Voice' }));
    const heading = await screen.findByRole('heading', { name: 'Talk to your local model by voice' });
    expect(document.activeElement).toBe(heading);

    // Shift+Tab from the programmatically focused heading wraps to the last control inside the dialog.
    const skipButton = screen.getByRole('button', { name: /Skip.*type/ });
    fireEvent.keyDown(heading, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(skipButton);
    expect(dialog.contains(document.activeElement)).toBe(true);

    // Forward Tab from the last control wraps to the first focusable control inside the dialog.
    const firstRadio = screen.getByRole('radio', { name: /Recommended/ });
    fireEvent.keyDown(skipButton, { key: 'Tab' });
    expect(document.activeElement).toBe(firstRadio);
    expect(dialog.contains(document.activeElement)).toBe(true);

    // Shift+Tab from the first control wraps back to the last control inside the dialog.
    fireEvent.keyDown(firstRadio, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(skipButton);

    // Forward Tab from the focused heading moves into the first control of step 2.
    heading.focus();
    fireEvent.keyDown(heading, { key: 'Tab' });
    expect(document.activeElement).toBe(firstRadio);

    // Non-default radio selection: choosing the second radio makes it the first sequential tab stop.
    const secondRadio = screen.getByRole('radio', { name: /More accurate/ });
    fireEvent.click(secondRadio);
    expect((secondRadio as HTMLInputElement).checked).toBe(true);
    secondRadio.focus();
    fireEvent.keyDown(secondRadio, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(skipButton);
    expect(dialog.contains(document.activeElement)).toBe(true);

    // Forward Tab from the last control wraps to the checked second radio (not the unchecked first radio).
    fireEvent.keyDown(skipButton, { key: 'Tab' });
    expect(document.activeElement).toBe(secondRadio);

    // Forward Tab from the step 2 heading lands on the checked second radio.
    heading.focus();
    fireEvent.keyDown(heading, { key: 'Tab' });
    expect(document.activeElement).toBe(secondRadio);

    // Dismissing the wizard removes inert from the dashboard.
    fireEvent.click(skipButton);
    await screen.findByText('What can I help you with?');
    expect(container.querySelector('[inert]')).toBeNull();
});

it('restores keyboard focus to the opener after removing inert under browser-faithful inert focus blocking', async () => {
    const originalFocus = HTMLElement.prototype.focus;
    const blockedFocusAttempts: HTMLElement[] = [];
    vi.spyOn(HTMLElement.prototype, 'focus').mockImplementation(function (this: HTMLElement, options?: FocusOptions) {
        if (this.closest('[inert]')) {
            blockedFocusAttempts.push(this);
            return;
        }
        return originalFocus.call(this, options);
    });
    try {
        mockDashboard({ voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' });
        function BrowserInertFixture() {
            const [open, setOpen] = useState(false);
            const backdropRef = useRef<HTMLDivElement>(null);
            const speech = useSpeechSetup(true, noEvents);
            useLayoutEffect(() => {
                const node = backdropRef.current;
                if (!node) return;
                if (open) node.setAttribute('inert', '');
                else node.removeAttribute('inert');
            }, [open]);
            return (
                <>
                    {open && (
                        <WelcomeWizard
                            speech={speech}
                            onDismiss={() => setOpen(false)}
                            onImages={() => {}}
                            onVision={() => {}}
                            downloadModelId={null}
                            downloadProgress={0}
                        />
                    )}
                    <div ref={backdropRef}>
                        <button type="button" onClick={() => setOpen(true)}>Open setup</button>
                    </div>
                </>
            );
        }

        render(<BrowserInertFixture />);
        const opener = screen.getByRole('button', { name: 'Open setup' });
        opener.focus();
        expect(document.activeElement).toBe(opener);

        fireEvent.click(opener);
        await chooseChat('installed-chat');
        fireEvent.click(screen.getByRole('button', { name: 'Next: Voice' }));
        await expectVoiceStep();

        // Pick non-default radio and verify Shift+Tab containment.
        const secondRadio = screen.getByRole('radio', { name: /More accurate/ });
        fireEvent.click(secondRadio);
        secondRadio.focus();
        const skipButton = screen.getByRole('button', { name: /Skip.*type/ });
        fireEvent.keyDown(secondRadio, { key: 'Tab', shiftKey: true });
        expect(document.activeElement).toBe(skipButton);

        // Close dialog: inert is cleared before opener.focus() runs, so opener regains focus cleanly.
        fireEvent.click(skipButton);
        await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Welcome Setup Wizard' })).toBeNull());
        expect(opener.closest('[inert]')).toBeNull();
        expect(document.activeElement).toBe(opener);
        expect(blockedFocusAttempts).not.toContain(opener);
    } finally {
        vi.restoreAllMocks();
    }
});

it('joins an existing non-activating chat download on Continue and surfaces async activation failure with Retry on step 2 and post-setup dashboard', async () => {
    vi.useFakeTimers();
    if (!HTMLElement.prototype.scrollTo) HTMLElement.prototype.scrollTo = () => {};
    if (!HTMLElement.prototype.scrollIntoView) HTMLElement.prototype.scrollIntoView = () => {};
    const storage = new Map<string, string>([['quenderin_disclaimer_accepted', 'true']]);
    vi.stubGlobal('localStorage', {
        getItem: (key: string) => storage.get(key) ?? null,
        setItem: (key: string, value: string) => { storage.set(key, value); },
        removeItem: (key: string) => { storage.delete(key); },
        clear: () => storage.clear(),
    });
    vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
    class StubSocket {
        static OPEN = 1;
        readyState = 1;
        send = vi.fn();
        close = vi.fn();
    }
    vi.stubGlobal('WebSocket', StubSocket);

    let catalogState: {
        activeModelId: string;
        downloadingModelId: string | null;
        downloadingActivate: boolean;
        pendingActivation: { modelId: string; status: 'pending' | 'activating' | 'failed'; code?: string; error: string | null } | null;
        catalog: typeof chatCatalog.catalog;
    } = {
        activeModelId: 'current-chat',
        // Pre-existing download started in Settings without activation.
        downloadingModelId: 'new-chat',
        downloadingActivate: false,
        pendingActivation: null,
        catalog: chatCatalog.catalog.map(m => ({ ...m })),
    };
    const writes: { method: string; url: string; body: unknown }[] = [];

    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
        const url = String(input);
        const method = init.method ?? 'GET';
        if (method !== 'GET') writes.push({ method, url, body: typeof init.body === 'string' ? JSON.parse(init.body) : null });
        if (url === '/api/models/catalog') return new Response(JSON.stringify(catalogState), { status: 200 });
        if (url === '/api/models/download') {
            catalogState = { ...catalogState, downloadingModelId: 'new-chat', downloadingActivate: true, pendingActivation: null };
            return new Response(JSON.stringify({ modelId: 'new-chat', status: 'downloading', joined: true, activate: true }), { status: 200 });
        }
        if (url === '/api/models/switch') {
            catalogState = {
                ...catalogState,
                activeModelId: 'new-chat',
                downloadingModelId: null,
                downloadingActivate: false,
                pendingActivation: null,
            };
            return new Response(JSON.stringify({ modelId: 'new-chat', activeModel: 'New chat' }), { status: 200 });
        }
        if (url === '/api/speech/models') return new Response(JSON.stringify(voiceCatalog), { status: 200 });
        if (url === '/api/speech/settings') return new Response(JSON.stringify({ voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' }), { status: 200 });
        if (url === '/api/speech/downloads' || url.startsWith('/api/speech/downloads/')) return new Response(url.endsWith('/downloads') ? '[]' : '{}', { status: url.endsWith('/downloads') ? 200 : 404 });
        if (url === '/health') return new Response(JSON.stringify({ activeModel: 'Current chat' }), { status: 200 });
        if (url === '/ready') return new Response(JSON.stringify({ ready: true, stage: 'ready' }), { status: 200 });
        return new Response(JSON.stringify({ sessions: [] }), { status: 200 });
    }));

    render(<App />);
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });

    // Wizard opens on an existing Settings download (activate: false) and shows Continue while downloading.
    const continueBtn = screen.getByRole('button', { name: 'Continue while downloading' });
    await act(async () => {
        fireEvent.click(continueBtn);
        await Promise.resolve();
        await Promise.resolve();
    });

    // Continue MUST register activation for the pre-existing download before advancing to Step 2.
    expect(writes).toContainEqual({ method: 'POST', url: '/api/models/download', body: { modelId: 'new-chat', activate: true } });
    expect(screen.getByRole('heading', { name: 'Talk to your local model by voice' })).toBeTruthy();

    // Download completes onto disk, then async activation fails on the server.
    catalogState = {
        activeModelId: 'current-chat',
        downloadingModelId: null,
        downloadingActivate: false,
        pendingActivation: {
            modelId: 'new-chat',
            status: 'failed',
            code: 'MODEL_ACTIVATION_FAILED',
            error: 'Could not activate the downloaded chat model. Try again or select a model in Settings.',
        },
        catalog: chatCatalog.catalog.map(m => m.id === 'new-chat' ? { ...m, isDownloaded: true } : { ...m }),
    };

    // Authoritative poll delivers the failure visibly on Step 2 with a Retry button.
    await act(async () => { await vi.advanceTimersByTimeAsync(1500); });
    const dialog = screen.getByRole('dialog', { name: 'Welcome Setup Wizard' });
    expect(within(dialog).getByRole('alert').textContent).toContain('Could not activate the downloaded chat model');
    expect(within(dialog).getByRole('button', { name: 'Retry chat model' })).toBeTruthy();

    // User finishes setup (Skip voice); the failure + Retry button remains visible on the post-setup dashboard.
    await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /Skip.*type/ }));
        await Promise.resolve();
        await Promise.resolve();
    });
    expect(screen.queryByRole('dialog', { name: 'Welcome Setup Wizard' })).toBeNull();
    expect(screen.getAllByRole('alert').some(el => el.textContent?.includes('Could not activate the downloaded chat model'))).toBe(true);

    // Clicking Retry on the post-setup dashboard switches to the already-downloaded model and clears the error.
    await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: 'Retry chat model' }));
        await Promise.resolve();
        await Promise.resolve();
    });
    expect(writes).toContainEqual({ method: 'POST', url: '/api/models/switch', body: { modelId: 'new-chat' } });
    expect(screen.queryAllByRole('alert').some(el => el.textContent?.includes('Could not activate the downloaded chat model'))).toBe(false);
});

it('keeps polling past progress 100 on step 1 until verification/activation reaches a terminal failure and clears stale downloading state', async () => {
    vi.useFakeTimers();
    let pollStage: 'downloading' | 'activating' | 'failed' = 'downloading';
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
        const url = String(input);
        const method = init.method ?? 'GET';
        if (url === '/api/models/catalog') {
            return new Response(JSON.stringify({
                activeModelId: 'current-chat',
                downloadingModelId: pollStage === 'downloading' ? 'new-chat' : null,
                downloadingActivate: pollStage === 'downloading',
                pendingActivation: pollStage === 'activating'
                    ? { modelId: 'new-chat', status: 'activating', code: null, error: null }
                    : pollStage === 'failed'
                        ? { modelId: 'new-chat', status: 'failed', code: 'MODEL_INTEGRITY_FAILED', error: 'The downloaded chat model failed verification. Download it again.' }
                        : null,
                catalog: chatCatalog.catalog,
            }), { status: 200 });
        }
        if (url === '/api/models/download' && method === 'POST') {
            pollStage = 'downloading';
            return new Response(JSON.stringify({ modelId: 'new-chat', status: 'downloading', joined: false, activate: true }), { status: 200 });
        }
        if (url === '/api/speech/models') return new Response(JSON.stringify(voiceCatalog), { status: 200 });
        if (url === '/api/speech/settings') return new Response(JSON.stringify({ voiceEnabled: false, modelId: null, autoSend: false, updatedAt: '2026-01-01T00:00:00Z' }), { status: 200 });
        if (url === '/api/speech/downloads' || url.startsWith('/api/speech/downloads/')) return new Response(url.endsWith('/downloads') ? '[]' : '{}', { status: url.endsWith('/downloads') ? 200 : 404 });
        return new Response('{}', { status: 404 });
    }));

    function Step1Harness({ progress }: { progress: number }) {
        const speech = useSpeechSetup(true, noEvents);
        return (
            <WelcomeWizard
                speech={speech}
                onDismiss={() => {}}
                onImages={() => {}}
                onVision={() => {}}
                downloadModelId="new-chat"
                downloadProgress={progress}
            />
        );
    }

    const { rerender } = render(<Step1Harness progress={50} />);
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    expect((screen.getByRole('combobox', { name: 'Chat model' }) as HTMLSelectElement).disabled).toBe(true);

    // WS progress hits 100 while server is still activating (verification/activation in flight).
    pollStage = 'activating';
    rerender(<Step1Harness progress={100} />);
    await act(async () => { await Promise.resolve(); await Promise.resolve(); });
    expect(screen.getByText(/Activating downloaded chat model/)).toBeTruthy();

    // Server reaches terminal failure after progress 100; authoritative poll clears stale downloading state.
    pollStage = 'failed';
    await act(async () => { await vi.advanceTimersByTimeAsync(1500); });
    expect(screen.getByRole('alert').textContent).toContain('failed verification');
    expect((screen.getByRole('combobox', { name: 'Chat model' }) as HTMLSelectElement).disabled).toBe(false);
    expect(screen.getByRole('button', { name: 'Retry chat model' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Next: Voice' })).toBeTruthy();
});
