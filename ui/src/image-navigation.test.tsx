import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import App from './App.js';

vi.mock('./hooks/useAgentSocket.js', () => ({ useAgentSocket: () => ({
    wsReady: true, logs: [], status: 'idle', currentUI: [],
    requiredAction: { code: 'MODEL_MISSING', message: 'A text model must be installed.' }, downloadProgress: 0,
    settings: { privacyLockEnabled: false, privacyPassphrase: '', themePreference: 'light' },
    resetSession: vi.fn(), clearRequiredAction: vi.fn(), updateSettings: vi.fn(),
}) }));
vi.mock('./components/GeneralChatArea.js', () => ({ GeneralChatArea: () => <div>Text chat</div> }));
vi.mock('./components/TroubleshooterGuide.js', () => ({ TroubleshooterGuide: () => <div role="dialog" aria-label="Text model setup">Text setup required</div> }));

beforeEach(() => {
    const storage = new Map<string, string>();
    vi.stubGlobal('localStorage', { getItem: (key: string) => storage.get(key) ?? null,
        setItem: (key: string, value: string) => { storage.set(key, value); }, removeItem: (key: string) => { storage.delete(key); }, clear: () => storage.clear() });
    localStorage.setItem('quenderin_disclaimer_accepted', 'true');
    vi.stubGlobal('innerWidth', 1440);
    vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
    vi.stubGlobal('fetch', vi.fn(async (input: string | URL | Request) => {
        const url = String(input);
        return new Response(JSON.stringify(url.includes('/health') ? { isBrainInstalled: false } : url.includes('/ready') ? { ready: false, stage: 'model_missing' } : { sessions: [] }), { status: 200 });
    }));
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe('image navigation before text setup', () => {
    it('opens Images from first-run setup without installing a text model or marking text setup complete', async () => {
        render(<App />);
        fireEvent.click(await screen.findByRole('button', { name: 'Use images first' }));
        await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Welcome Setup Wizard' })).toBeNull());
        expect(screen.queryByRole('dialog', { name: 'Text model setup' })).toBeNull();
        expect(screen.getByRole('heading', { name: 'Images', level: 1 })).toBeTruthy();
        expect(screen.getByText('Image generation requires the Quenderin desktop app.')).toBeTruthy();
        expect(localStorage.getItem('quenderin_setup_complete')).toBeNull();
        expect(vi.mocked(fetch).mock.calls.some(call => String(call[0]).includes('/api/models/download'))).toBe(false);
    });
    it('retains the scene caption across sidebar navigation', async () => {
        localStorage.setItem('quenderin_setup_complete', 'true'); localStorage.setItem('quenderin_sidebar_open', 'true');
        render(<App />);
        fireEvent.click(screen.getByRole('button', { name: 'Images' }));
        const caption = screen.getByLabelText('Scene caption'); fireEvent.change(caption, { target: { value: 'Keep this garden caption' } });
        fireEvent.click(screen.getByRole('button', { name: 'Chat' }));
        fireEvent.click(screen.getByRole('button', { name: 'Images' }));
        expect((screen.getByLabelText('Scene caption') as HTMLTextAreaElement).value).toBe('Keep this garden caption');
    });
});
