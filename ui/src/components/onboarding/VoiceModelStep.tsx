import { useEffect, useId, useRef, useState } from 'react';
import { Model } from '../../vendor/handy/components/onboarding/screens/Model.js';
import type { SpeechSetup } from '../../lib/speech/useSpeechSetup.js';

export function VoiceModelStep({ speech, onFinish }: { speech: SpeechSetup; onFinish: () => void }) {
    const title = useId();
    const heading = useRef<HTMLHeadingElement>(null);
    const [skipError, setSkipError] = useState<string | null>(null);
    useEffect(() => { heading.current?.focus(); }, []);

    async function skip() {
        setSkipError(null);
        if (speech.settings && !speech.settings.voiceEnabled) {
            onFinish();
            return;
        }
        try {
            await speech.updateSettings({ voiceEnabled: false });
            onFinish();
        } catch {
            if (!speech.settings?.voiceEnabled) {
                onFinish();
                return;
            }
            const message = 'Could not turn off voice. Reconnect and try again.';
            setSkipError(message);
            throw new Error(message);
        }
    }

    return (
        <section aria-labelledby={title} className="space-y-4">
            <div>
                <p className="text-xs font-medium text-qteal-700 dark:text-qteal-300">Optional</p>
                <h2 id={title} ref={heading} tabIndex={-1} className="mt-1 text-lg font-semibold">Talk to your local model by voice</h2>
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">Choose a speech model. Quenderin transcribes your microphone audio on this computer.</p>
            </div>
            {speech.catalog ? <Model catalog={speech.catalog} downloads={speech.downloads.snapshots} settings={speech.settings}
                onAction={(action, id) => action === 'remove' ? speech.removeModel(id) : speech.downloads.run(action, id)} onUse={id => speech.updateSettings({ modelId: id, voiceEnabled: true })}
                onSelect={speech.refreshDownload} onSkip={skip} onFinish={onFinish} /> : (
                <div className="space-y-2">
                    {speech.loadError ? <p role="alert" className="text-sm">{speech.loadError}</p> : <p role="status" className="text-sm">Loading voice models…</p>}
                    {speech.loadError && <button type="button" className="rounded-lg border px-3 py-2 text-sm" onClick={() => void speech.load()}>Retry</button>}
                    <button type="button" className="rounded-lg px-3 py-2 text-sm" onClick={() => void skip().catch(() => {})}>Skip — I’ll type</button>
                    {skipError && <p role="alert">{skipError}</p>}
                </div>
            )}
        </section>
    );
}
