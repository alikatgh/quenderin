import { useState } from 'react';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { GeneralChatArea } from '../src/components/GeneralChatArea.js';

const modelId = 'parakeet-unified-en-0.6b';
const recognizedText = 'send the weekly update';
const typedText = 'Please';
const stopTrack = vi.fn();
const getUserMedia = vi.fn<MediaDevices['getUserMedia']>();
const sendChat = vi.fn();
const closeAudio = vi.fn(async () => {});
const openAudio = vi.fn();
const decodeAudio = vi.fn(async (_bytes: ArrayBuffer) => ({
    sampleRate: 16_000, numberOfChannels: 2, length: 2,
    getChannelData: (channel: number) => channel === 0 ? Float32Array.of(1, -1) : Float32Array.of(0, -1),
}));
const mediaDevicesDescriptor = Object.getOwnPropertyDescriptor(navigator, 'mediaDevices');

class FixtureRecorder extends EventTarget {
    state: RecordingState = 'inactive';
    readonly mimeType = 'audio/webm';

    start() { this.state = 'recording'; }

    stop() {
        this.state = 'inactive';
        this.dispatchEvent(new BlobEvent('dataavailable', { data: new Blob(['synthetic capture'], { type: this.mimeType }) }));
        this.dispatchEvent(new Event('stop'));
    }
}

class FixtureAudioContext {
    constructor(options: AudioContextOptions) { openAudio(options); }
    decodeAudioData = decodeAudio;
    close = closeAudio;
}

function Composer() {
    const [draft, setDraft] = useState(typedText);
    return <GeneralChatArea logs={[]} status="idle" requiredAction={null} onOpenSettings={() => {}}
        onOpenTroubleshooter={() => {}} chatInput={draft} setChatInput={setDraft} onSend={(message, attachments) => {
            sendChat(message, attachments);
            setDraft('');
        }} onStop={() => {}} voice={{ modelId, onSettings: () => {} }} activePresetId="general" onSwitchPreset={() => {}} />;
}

function renderComposer(autoSend = false) {
    const transcribe = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({
        text: recognizedText, rawText: recognizedText, language: 'en', modelId, autoSend,
        backend: 'transcribe.cpp', durationMs: 1, truncated: false, segments: [],
    })));
    vi.stubGlobal('fetch', transcribe);
    render(<Composer />);
    screen.getByRole('log', { name: 'Conversation' }).scrollTo = vi.fn();
    return { transcribe, mic: screen.getByRole('button', { name: /Hold to talk/ }), composer: screen.getByRole<HTMLTextAreaElement>('textbox') };
}

describe('chat push-to-talk with mocked microphone and local speech API', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        getUserMedia.mockReset().mockResolvedValue({ getTracks: () => [{ stop: stopTrack }] } as unknown as MediaStream);
        Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } });
        vi.stubGlobal('MediaRecorder', FixtureRecorder);
        vi.stubGlobal('AudioContext', FixtureAudioContext);
    });

    afterEach(() => {
        cleanup();
        if (mediaDevicesDescriptor) Object.defineProperty(navigator, 'mediaDevices', mediaDevicesDescriptor);
        else Reflect.deleteProperty(navigator, 'mediaDevices');
        vi.unstubAllGlobals();
    });

    it.each([
        ['NotAllowedError', /Allow microphone access in this page’s site permissions/],
        ['NotFoundError', /No microphone found/],
    ])('explains %s and leaves typed chat available', async (name, hint) => {
        // jsdom's DOMException uses a different Error prototype from the Vitest test realm.
        getUserMedia.mockRejectedValueOnce(Object.assign(new Error('Microphone fixture error'), { name }));
        const { mic, transcribe, composer } = renderComposer();
        expect(getUserMedia).not.toHaveBeenCalled();
        fireEvent.keyDown(mic, { key: ' ' });
        expect((await screen.findByRole('alert')).textContent).toMatch(hint);
        fireEvent.keyUp(mic, { key: ' ' });
        expect(getUserMedia).toHaveBeenCalledExactlyOnceWith({ audio: { channelCount: { ideal: 1 } }, video: false });
        expect(transcribe).not.toHaveBeenCalled();
        expect(composer.value).toBe(typedText);
        fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
        expect(sendChat).toHaveBeenCalledExactlyOnceWith(typedText, []);
    });

    it.each([false, true])('inserts a local WAV transcript and respects autoSend=%s', async autoSend => {
        const { mic, transcribe, composer } = renderComposer(autoSend);
        const chord = { key: 'M', code: 'KeyM', ctrlKey: true, shiftKey: true };
        fireEvent.keyDown(window, chord);
        await waitFor(() => expect(mic.getAttribute('aria-pressed')).toBe('true'));
        expect(transcribe).not.toHaveBeenCalled();
        fireEvent.keyUp(window, chord);

        await waitFor(() => expect(transcribe).toHaveBeenCalledTimes(1));
        const [url, request] = transcribe.mock.calls[0];
        expect(url).toBe(`/api/speech/transcribe?modelId=${modelId}`);
        expect(request.method).toBe('POST');
        expect(new Headers(request.headers).get('Content-Type')).toBe('audio/wav');
        expect(openAudio).toHaveBeenCalledExactlyOnceWith({ sampleRate: 16_000 });
        const blob = request.body as Blob;
        expect(blob.type).toBe('audio/wav');
        const bytes = await blob.arrayBuffer();
        const wav = new DataView(bytes);
        expect(new TextDecoder().decode(bytes.slice(0, 4))).toBe('RIFF');
        expect(new TextDecoder().decode(bytes.slice(8, 12))).toBe('WAVE');
        expect(wav.getUint16(20, true)).toBe(1);
        expect(wav.getUint16(22, true)).toBe(1);
        expect(wav.getUint32(24, true)).toBe(16_000);
        expect(wav.getUint16(34, true)).toBe(16);
        expect(wav.getUint32(40, true)).toBe(4);
        expect([wav.getInt16(44, true), wav.getInt16(46, true)]).toEqual([16_384, -32_768]);
        expect(stopTrack).toHaveBeenCalled();
        expect(closeAudio).toHaveBeenCalledTimes(1);

        const message = `${typedText} ${recognizedText}`;
        if (autoSend) {
            await waitFor(() => expect(sendChat).toHaveBeenCalledExactlyOnceWith(message, []));
            expect(composer.value).toBe('');
        } else {
            await waitFor(() => expect(composer.value).toBe(message));
            expect(sendChat).not.toHaveBeenCalled();
            fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
            expect(sendChat).toHaveBeenCalledExactlyOnceWith(message, []);
        }
    });
});
