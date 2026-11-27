import { useEffect, useId, useRef } from 'react';
import { Loader2, Mic } from 'lucide-react';
import { PUSH_TO_TALK_SHORTCUT_LABEL, usePushToTalk } from '../lib/speech/useMicrophone.js';

type Props = Parameters<typeof usePushToTalk>[0];

export function VoiceInputButton(props: Props) {
    const { state, busy, requesting, start, stop, cancel } = usePushToTalk(props);
    const keyHeld = useRef(false);
    const pointer = useRef<number | null>(null);
    const statusId = useId();

    useEffect(() => {
        if (props.disabled) return;
        const keydown = (event: KeyboardEvent) => {
            if (event.key === 'Escape') {
                keyHeld.current = false;
                cancel();
            }
            if (event.code !== 'KeyM' || !event.shiftKey || !(event.ctrlKey || event.metaKey)
                || event.altKey || event.isComposing || event.defaultPrevented) return;
            event.preventDefault();
            if (!event.repeat && !keyHeld.current) {
                keyHeld.current = true;
                void start();
            }
        };
        const keyup = (event: KeyboardEvent) => {
            if (!keyHeld.current || (event.code !== 'KeyM' && !['Shift', 'Control', 'Meta'].includes(event.key))) return;
            keyHeld.current = false;
            void stop();
        };
        const interrupt = () => { keyHeld.current = false; pointer.current = null; cancel(); };
        const visibility = () => { if (document.hidden) interrupt(); };
        window.addEventListener('keydown', keydown);
        window.addEventListener('keyup', keyup);
        window.addEventListener('blur', interrupt);
        document.addEventListener('visibilitychange', visibility);
        return () => {
            window.removeEventListener('keydown', keydown);
            window.removeEventListener('keyup', keyup);
            window.removeEventListener('blur', interrupt);
            document.removeEventListener('visibilitychange', visibility);
            keyHeld.current = false;
        };
    }, [props.disabled, start, stop, cancel]);

    const label = `Hold to talk (${PUSH_TO_TALK_SHORTCUT_LABEL})`;
    const hint = state.error ?? (busy ? 'Transcribing on this computer…'
        : state.recording ? 'Recording… release to transcribe.'
        : requesting ? 'Allow microphone access, then hold to talk.'
        : state.permission === 'unsupported' ? 'Microphone recording is unavailable in this browser.'
        : state.permission === 'prompt' ? 'Hold to talk. Quenderin will ask for microphone access.'
        : 'Hold to talk. Release to transcribe.');
    const showStatus = state.error || busy || state.recording || requesting || state.permission === 'unsupported';
    const holdKey = (key: string) => key === ' ' || key === 'Enter';

    return (
        <>
            <button type="button" aria-label={label} title={label}
                aria-keyshortcuts="Control+Shift+M Meta+Shift+M" aria-describedby={statusId}
                aria-pressed={state.recording} aria-busy={busy} disabled={props.disabled || busy || state.permission === 'unsupported'}
                onPointerDown={event => {
                    if (event.button !== 0 || pointer.current !== null) return;
                    pointer.current = event.pointerId;
                    event.currentTarget.setPointerCapture?.(event.pointerId);
                    void start();
                }}
                onPointerUp={event => {
                    if (pointer.current !== event.pointerId) return;
                    pointer.current = null;
                    void stop();
                }}
                onPointerCancel={() => { pointer.current = null; cancel(); }}
                onLostPointerCapture={() => { if (pointer.current !== null) { pointer.current = null; cancel(); } }}
                onKeyDown={event => {
                    if (!holdKey(event.key)) return;
                    event.preventDefault();
                    if (!event.repeat) void start();
                }}
                onKeyUp={event => { if (holdKey(event.key)) { event.preventDefault(); void stop(); } }}
                onBlur={() => { if (pointer.current === null && !keyHeld.current && (state.recording || requesting)) cancel(); }}
                onClick={event => {
                    // A synthesized activation from assistive technology can use press-again-to-stop.
                    if (event.detail === 0) void (state.recording ? stop() : start());
                }}
                className={`touch-none rounded-lg p-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-qteal-500 disabled:opacity-50 ${state.recording ? 'bg-red-600 text-white' : 'text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800'}`}>
                {busy ? <Loader2 aria-hidden="true" className="size-[18px] motion-safe:animate-spin" />
                    : <Mic aria-hidden="true" className="size-[18px]" />}
            </button>
            <span id={statusId} role={state.error ? 'alert' : 'status'}
                className={showStatus
                    ? 'pointer-events-none absolute bottom-full end-0 z-10 mb-3 w-max max-w-[min(22rem,75vw)] rounded-lg border border-zinc-200 bg-white px-3 py-2 text-xs text-zinc-800 shadow-sm dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100'
                    : 'sr-only'}>{hint}</span>
        </>
    );
}
