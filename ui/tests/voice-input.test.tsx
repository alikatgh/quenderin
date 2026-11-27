import { useState } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { VoiceInputButton } from '../src/components/VoiceInputButton.js';
import { ChatArea } from '../src/components/ChatArea.js';
import { GeneralChatArea } from '../src/components/GeneralChatArea.js';
import { blobBytes, setupMicrophone } from './microphoneFixture.js';

let mic: ReturnType<typeof setupMicrophone>;
beforeEach(() => {
    mic = setupMicrophone();
    if (!HTMLElement.prototype.scrollIntoView) HTMLElement.prototype.scrollIntoView = () => {};
    if (!HTMLElement.prototype.scrollTo) HTMLElement.prototype.scrollTo = () => {};
    vi.stubGlobal('fetch', vi.fn(async () => new Response('[]', { status: 200 })));
});
afterEach(() => { cleanup(); mic.restore(); vi.unstubAllGlobals(); });
const button = () => screen.getByRole('button', { name: /Hold to talk/ });
const pointerDown = () => fireEvent.pointerDown(button(), { button: 0, pointerId: 1 });
const pointerUp = () => fireEvent.pointerUp(button(), { button: 0, pointerId: 1 });
const record = async () => {
    pointerDown();
    await waitFor(() => expect(button().getAttribute('aria-pressed')).toBe('true'));
    pointerUp();
};

describe('push-to-talk capture', () => {
    it('requests permission on the first hold and uploads a 16 kHz mono PCM16 recording on release', async () => {
        const transcribe = vi.fn(async () => ({ text: 'Hello locally', autoSend: false }));
        const insert = vi.fn();
        render(<VoiceInputButton transcribe={transcribe} onTranscript={insert} />);
        expect(screen.getByText(/will ask for microphone access/)).toBeTruthy();
        expect(mic.getUserMedia).not.toHaveBeenCalled();
        pointerDown();
        await waitFor(() => expect(button().getAttribute('aria-pressed')).toBe('true'));
        expect(mic.getUserMedia).toHaveBeenCalledExactlyOnceWith({ audio: { channelCount: { ideal: 1 } }, video: false });
        expect(transcribe).not.toHaveBeenCalled();
        pointerUp();
        await waitFor(() => expect(insert).toHaveBeenCalledWith({ text: 'Hello locally', autoSend: false }));
        expect(mic.audioOptions).toHaveBeenCalledWith({ sampleRate: 16000 });
        expect(mic.close).toHaveBeenCalledOnce();
        expect(mic.records[0].stop).toHaveBeenCalledOnce();
        expect(mic.stop).toHaveBeenCalled();
        const wav = transcribe.mock.calls[0][0] as Blob;
        expect(wav.type).toBe('audio/wav');
        const bytes = new DataView(await blobBytes(wav));
        expect(bytes.getUint32(0)).toBe(0x52494646);
        expect(bytes.getUint16(20, true)).toBe(1);
        expect(bytes.getUint16(22, true)).toBe(1);
        expect(bytes.getUint32(24, true)).toBe(16000);
        expect(bytes.getUint16(34, true)).toBe(16);
        expect([44, 46, 48].map(i => bytes.getInt16(i, true))).toEqual([0, -32768, 16384]);
    });

    it.each([
        ['NotAllowedError', /Allow microphone access in this page/],
        ['NotFoundError', /No microphone found/],
        ['NotReadableError', /Could not open the microphone/],
    ])('explains %s and allows the next permission attempt', async (name, copy) => {
        mic.getUserMedia.mockRejectedValueOnce(new DOMException('fixture', name));
        const transcribe = vi.fn(async () => ({ text: 'Permission ready', autoSend: false }));
        render(<VoiceInputButton transcribe={transcribe} onTranscript={vi.fn()} />);
        pointerDown();
        await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(copy));
        pointerUp();
        expect(transcribe).not.toHaveBeenCalled();
        await record();
        expect(mic.getUserMedia).toHaveBeenCalledTimes(2);
        await waitFor(() => expect(transcribe).toHaveBeenCalledOnce());
    });

    it('shows unsupported browsers without requesting media', () => {
        vi.stubGlobal('MediaRecorder', undefined);
        render(<VoiceInputButton transcribe={vi.fn()} onTranscript={vi.fn()} />);
        expect((button() as HTMLButtonElement).disabled).toBe(true);
        expect(screen.getByText('Microphone recording is unavailable in this browser.')).toBeTruthy();
        expect(mic.getUserMedia).not.toHaveBeenCalled();
    });

    it('checks the macOS desktop bridge and gives System Settings instructions', async () => {
        const bridge = { status: vi.fn(async () => 'denied'), request: vi.fn(async () => false) };
        vi.stubGlobal('quenderinMicrophone', bridge);
        render(<VoiceInputButton transcribe={vi.fn()} onTranscript={vi.fn()} />);
        expect((await screen.findByRole('alert')).textContent).toMatch(/System Settings.*Privacy & Security.*Microphone/);
        pointerDown();
        await waitFor(() => expect(bridge.request).toHaveBeenCalledOnce());
        expect(bridge.status).toHaveBeenCalledOnce();
        expect(mic.getUserMedia).not.toHaveBeenCalled();
    });

    it('releases a late permission grant without creating a recorder after the user lets go', async () => {
        let grant: (stream: MediaStream) => void;
        mic.getUserMedia.mockImplementationOnce(() => new Promise(resolve => { grant = resolve; }));
        const transcribe = vi.fn();
        render(<VoiceInputButton transcribe={transcribe} onTranscript={vi.fn()} />);
        pointerDown();
        pointerUp();
        await act(async () => grant(mic.stream));
        expect(mic.records).toHaveLength(0);
        expect(mic.stop).toHaveBeenCalledOnce();
        expect(transcribe).not.toHaveBeenCalled();
    });

    it('ignores a deferred permission rejection from a cancelled attempt once a new recording starts', async () => {
        let failFirst!: (error: Error) => void;
        mic.getUserMedia
            .mockImplementationOnce(() => new Promise((_resolve, reject) => { failFirst = reject; }))
            .mockResolvedValueOnce(mic.stream);
        const transcribe = vi.fn(async () => ({ text: 'Second recording', autoSend: false }));
        const insert = vi.fn();
        render(<VoiceInputButton transcribe={transcribe} onTranscript={insert} />);

        // First press starts acquisition, then user lets go (aborting attempt 1).
        pointerDown();
        pointerUp();

        // Second press immediately acquires microphone and begins recording.
        pointerDown();
        await waitFor(() => expect(button().getAttribute('aria-pressed')).toBe('true'));

        // Deferred rejection from attempt 1 arrives mid-recording and must NOT clobber state.
        await act(async () => failFirst(new DOMException('Late denial', 'NotAllowedError')));
        expect(screen.queryByRole('alert')).toBeNull();
        expect(button().getAttribute('aria-pressed')).toBe('true');

        // Releasing attempt 2 transcribes normally.
        pointerUp();
        await waitFor(() => expect(insert).toHaveBeenCalledWith({ text: 'Second recording', autoSend: false }));
    });

    it('holds Ctrl+Shift+M and releases when a modifier key lifts', async () => {
        const transcribe = vi.fn(async () => ({ text: 'Spoken shortcut', autoSend: true }));
        const insert = vi.fn();
        render(<VoiceInputButton transcribe={transcribe} onTranscript={insert} />);
        expect(button().getAttribute('aria-keyshortcuts')).toBe('Control+Shift+M Meta+Shift+M');
        fireEvent.keyDown(window, { code: 'KeyM', key: 'M', shiftKey: true, ctrlKey: true });
        await waitFor(() => expect(button().getAttribute('aria-pressed')).toBe('true'));
        fireEvent.keyDown(window, { code: 'KeyM', key: 'M', shiftKey: true, ctrlKey: true, repeat: true });
        expect(mic.getUserMedia).toHaveBeenCalledOnce();
        fireEvent.keyUp(window, { key: 'Control' });
        await waitFor(() => expect(insert).toHaveBeenCalledWith({ text: 'Spoken shortcut', autoSend: true }));
    });

    it.each(['escape', 'blur', 'unmount'])('cancels recording and releases tracks on %s', async reason => {
        const transcribe = vi.fn();
        const { unmount } = render(<VoiceInputButton transcribe={transcribe} onTranscript={vi.fn()} />);
        pointerDown();
        await waitFor(() => expect(button().getAttribute('aria-pressed')).toBe('true'));
        if (reason === 'escape') fireEvent.keyDown(window, { key: 'Escape' });
        if (reason === 'blur') fireEvent.blur(window);
        if (reason === 'unmount') unmount();
        expect(mic.records[0].stop).toHaveBeenCalledOnce();
        expect(mic.stop).toHaveBeenCalled();
        expect(transcribe).not.toHaveBeenCalled();
    });

    it('indicates in-flight transcription and shows the local error on failure', async () => {
        let reject: (error: Error) => void;
        const transcribe = vi.fn(() => new Promise<never>((_resolve, fail) => { reject = fail; }));
        render(<VoiceInputButton transcribe={transcribe} onTranscript={vi.fn()} />);
        await record();
        await waitFor(() => expect(transcribe).toHaveBeenCalledOnce());
        expect(button().getAttribute('aria-busy')).toBe('true');
        expect((button() as HTMLButtonElement).disabled).toBe(true);
        await act(async () => reject(new Error('Pinned speech runtime is unavailable.')));
        expect(screen.getByRole('alert').textContent).toMatch(/Pinned speech runtime/);
        expect((button() as HTMLButtonElement).disabled).toBe(false);
    });
});

describe('composer transcription', () => {
    function mockSpeech(autoSend: boolean) {
        const fetch = vi.fn(async (url: string) => new Response(JSON.stringify(url.startsWith('/api/speech/transcribe')
            ? { text: 'local transcript', autoSend }
            : { templates: [] }), { headers: { 'Content-Type': 'application/json' } }));
        vi.stubGlobal('fetch', fetch);
        return fetch;
    }

    it.each([
        ['General Chat', false, false],
        ['General Chat', true, true],
        ['Agent Chat', false, false],
        ['Agent Chat', true, false],
    ] as const)('%s appends speech with auto-send=%s (auto-submits=%s)', async (view, autoSend, shouldSubmit) => {
        const fetch = mockSpeech(autoSend);
        const send = vi.fn();
        const voice = { modelId: 'local-fixture', onSettings: vi.fn() };
        function Composer() {
            const [draft, setDraft] = useState('Draft');
            return view === 'General Chat'
                ? <GeneralChatArea logs={[]} status="idle" requiredAction={null} onOpenSettings={vi.fn()} onOpenTroubleshooter={vi.fn()}
                    chatInput={draft} setChatInput={setDraft} onSend={send} onStop={vi.fn()} voice={voice} activePresetId="general" onSwitchPreset={vi.fn()} />
                : <ChatArea logs={[]} status="idle" goal={draft} setGoal={setDraft} onStart={send} setCurrentView={vi.fn()}
                    voice={voice} agentPaused={false} onPause={vi.fn()} onResume={vi.fn()} />;
        }
        render(<Composer />);
        await record();
        await waitFor(() => expect((screen.getByRole('textbox') as HTMLTextAreaElement).value).toBe('Draft local transcript'));
        expect(fetch).toHaveBeenCalledWith('/api/speech/transcribe?modelId=local-fixture', expect.objectContaining({
            body: expect.any(Blob), method: 'POST', headers: expect.any(Headers), signal: expect.any(AbortSignal),
        }));
        if (shouldSubmit) expect(send.mock.calls[0][0]).toBe('Draft local transcript');
        else expect(send).not.toHaveBeenCalled();
    });

    it('points to Voice settings before a model is installed', () => {
        const open = vi.fn();
        render(<ChatArea logs={[]} status="idle" goal="" setGoal={vi.fn()} onStart={vi.fn()} setCurrentView={vi.fn()}
            voice={{ onSettings: open }} agentPaused={false} onPause={vi.fn()} onResume={vi.fn()} />);
        expect(screen.queryByRole('button', { name: /Hold to talk/ })).toBeNull();
        fireEvent.click(screen.getByRole('button', { name: 'Set up voice dictation in Settings' }));
        expect(open).toHaveBeenCalledOnce();
        expect(mic.getUserMedia).not.toHaveBeenCalled();
    });
});
