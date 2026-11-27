import { useCallback, useEffect, useRef, useState } from 'react';
import type { MicrophonePermission, MicrophoneState, SpeechTranscriptionResponse } from './types.js';
import { blobToWav16k } from './wav.js';

type AccessStatus = 'not-determined' | 'granted' | 'denied' | 'restricted' | 'unknown';
type MediaBridge = { status: () => Promise<AccessStatus>; request: () => Promise<boolean> };
const mediaBridge = () => (window as Window & { quenderinMicrophone?: MediaBridge }).quenderinMicrophone;
const constraints = { audio: { channelCount: { ideal: 1 } }, video: false };
const supported = () => !!navigator.mediaDevices?.getUserMedia
    && typeof MediaRecorder !== 'undefined' && typeof AudioContext !== 'undefined';
const deniedHint = () => mediaBridge()
    ? 'Allow Quenderin under System Settings → Privacy & Security → Microphone, then reopen the app.'
    : 'Allow microphone access in this page’s site permissions and in your system microphone settings, then try again.';
const stopTracks = (stream?: MediaStream) => stream?.getTracks().forEach(track => track.stop());

export interface MicrophoneController {
    readonly permission: MicrophonePermission;
    readonly error: string | null;
    acquire(signal: AbortSignal): Promise<MediaStream | null>;
}

export function useMicrophone(): MicrophoneController {
    const [permission, setPermission] = useState<MicrophonePermission>(() => supported() ? 'prompt' : 'unsupported');
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        if (!supported()) return;
        let live = true;
        let subscription: PermissionStatus | undefined;
        const bridge = mediaBridge();
        const onChange = () => {
            if (!live || !subscription) return;
            setPermission(subscription.state);
            setError(subscription.state === 'denied' ? deniedHint() : null);
        };
        if (bridge) {
            void bridge.status().then(status => {
                if (!live) return;
                if (status === 'denied' || status === 'restricted') {
                    setPermission('denied');
                    setError(deniedHint());
                } else if (status === 'granted') {
                    setPermission('granted');
                }
            }).catch(() => {});
        } else if (navigator.permissions?.query) {
            void navigator.permissions.query({ name: 'microphone' as PermissionName }).then(result => {
                if (!live) return;
                subscription = result;
                onChange();
                result.addEventListener('change', onChange);
            }).catch(() => {});
        }
        return () => { live = false; subscription?.removeEventListener('change', onChange); };
    }, []);

    const acquire = useCallback(async (signal: AbortSignal) => {
        if (!supported()) return null;
        setError(null);
        try {
            const bridge = mediaBridge();
            if (bridge && !await bridge.request()) throw new DOMException('Microphone access denied.', 'NotAllowedError');
            if (signal.aborted) return null;
            const stream = await navigator.mediaDevices.getUserMedia(constraints);
            setPermission('granted');
            if (signal.aborted) {
                stopTracks(stream);
                return null;
            }
            return stream;
        } catch (cause) {
            const name = cause && typeof cause === 'object' && 'name' in cause ? cause.name : '';
            if (name === 'NotAllowedError' || name === 'PermissionDeniedError' || name === 'SecurityError') {
                setPermission('denied');
                setError(deniedHint());
            } else if (name === 'NotFoundError' || name === 'DevicesNotFoundError') {
                setPermission('no-device');
                setError('No microphone found. Connect one or select an input in system sound settings.');
            } else {
                setError('Could not open the microphone. Check the current input and close other apps using it.');
            }
            return null;
        }
    }, []);

    return { permission, error, acquire };
}

export const PUSH_TO_TALK_SHORTCUT_LABEL = 'Ctrl/⌘+Shift+M';
const MAX_RECORDING_MS = 2 * 60 * 1000;

interface Capture {
    abort: AbortController;
    stream?: MediaStream;
    recorder?: MediaRecorder;
    chunks: Blob[];
    limit?: ReturnType<typeof setTimeout>;
    sending: boolean;
}

type DictationResult = Pick<SpeechTranscriptionResponse, 'text' | 'autoSend'>;

export function usePushToTalk({ transcribe, onTranscript, disabled = false }: {
    transcribe: (wav: Blob, signal: AbortSignal) => Promise<DictationResult>;
    onTranscript: (result: DictationResult) => void;
    disabled?: boolean;
}) {
    const microphone = useMicrophone();
    const capture = useRef<Capture | null>(null);
    const [recording, setRecording] = useState(false);
    const [requesting, setRequesting] = useState(false);
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const latest = useRef({ transcribe, onTranscript, acquire: microphone.acquire, disabled });
    latest.current = { transcribe, onTranscript, acquire: microphone.acquire, disabled };

    const release = useCallback(() => {
        const current = capture.current;
        if (!current) return;
        capture.current = null;
        current.abort.abort();
        clearTimeout(current.limit);
        if (current.recorder && current.recorder.state !== 'inactive') current.recorder.stop();
        stopTracks(current.stream);
    }, []);

    const cancel = useCallback(() => {
        release();
        setRecording(false);
        setRequesting(false);
        setBusy(false);
    }, [release]);

    const stop = useCallback(() => {
        const current = capture.current;
        if (!current || current.sending) return;
        const recorder = current.recorder;
        if (!recorder || recorder.state === 'inactive') {
            cancel();
            return;
        }
        current.sending = true;
        clearTimeout(current.limit);
        setRecording(false);
        setBusy(true);
        recorder.stop();
        stopTracks(current.stream);
    }, [cancel]);

    const start = useCallback(async () => {
        if (capture.current || latest.current.disabled || !supported()) return;
        const current: Capture = { abort: new AbortController(), chunks: [], sending: false };
        capture.current = current;
        const { signal } = current.abort;
        setError(null);
        setRequesting(true);
        const stream = await latest.current.acquire(signal);
        if (signal.aborted || capture.current !== current) {
            stopTracks(stream ?? undefined);
            return;
        }
        setRequesting(false);
        if (!stream) {
            cancel();
            return;
        }
        current.stream = stream;
        try {
            const recorder = new MediaRecorder(stream);
            current.recorder = recorder;
            recorder.addEventListener('dataavailable', event => { if (event.data.size) current.chunks.push(event.data); });
            recorder.addEventListener('error', () => {
                if (capture.current !== current) return;
                cancel();
                setError('Microphone recording failed. Try again.');
            }, { once: true });
            recorder.addEventListener('stop', () => {
                if (signal.aborted) return;
                void (async () => {
                    try {
                        const wav = await blobToWav16k(new Blob(current.chunks, { type: recorder.mimeType }));
                        if (signal.aborted) return;
                        const result = await latest.current.transcribe(wav, signal);
                        if (signal.aborted) return;
                        if (!result.text.trim()) setError('No speech detected. Try speaking closer to the microphone.');
                        else latest.current.onTranscript(result);
                    } catch (cause) {
                        if (!signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not transcribe the recording.');
                    } finally {
                        if (capture.current === current) cancel();
                    }
                })();
            }, { once: true });
            recorder.start();
            setRecording(true);
            current.limit = setTimeout(stop, MAX_RECORDING_MS);
        } catch {
            cancel();
            setError('Could not start recording. Check your microphone and try again.');
        }
    }, [cancel, stop]);

    useEffect(() => release, [release]);
    useEffect(() => { if (disabled) cancel(); }, [disabled, cancel]);

    const state: MicrophoneState = { permission: microphone.permission, error: error ?? microphone.error, recording };
    return { state, start, stop, cancel, requesting, busy };
}
