import { useState } from 'react';
import { Mic } from 'lucide-react';
import { Model } from '../../vendor/handy/components/onboarding/screens/Model.js';
import type { SpeechSetup } from '../../lib/speech/useSpeechSetup.js';

export function VoiceSettingsSection({ speech }: { speech: SpeechSetup }) {
    const [error, setError] = useState<string | null>(null);
    const [saving, setSaving] = useState(false);
    const { catalog, downloads, settings } = speech;

    async function toggle(key: 'voiceEnabled' | 'autoSend', value: boolean) {
        setSaving(true);
        setError(null);
        try { await speech.updateSettings({ [key]: value }); } catch (cause) {
            setError(cause instanceof Error ? cause.message : 'Could not save voice settings.');
        } finally { setSaving(false); }
    }

    return (
        <section aria-labelledby="voice-settings-heading" className="space-y-4 rounded-xl border border-zinc-200 p-4 dark:border-zinc-800">
            <div>
                <h2 id="voice-settings-heading" className="flex items-center gap-2 text-sm font-semibold">
                    <Mic aria-hidden="true" className="size-4 text-qteal-600 dark:text-qteal-300" /> Voice
                </h2>
                <p className="mt-1 text-xs text-zinc-600 dark:text-zinc-400">Use a local speech model to dictate into chat.</p>
            </div>
            {catalog ? <>
                <div className="flex flex-wrap gap-x-6 gap-y-2">
                    <label className="flex items-center gap-2 text-sm">
                        <input type="checkbox" checked={settings?.voiceEnabled ?? false} disabled={saving || !settings?.modelId}
                            onChange={e => void toggle('voiceEnabled', e.target.checked)} className="accent-qteal-600" /> Enable voice dictation
                    </label>
                    <label className="flex items-center gap-2 text-sm">
                        <input type="checkbox" checked={settings?.autoSend ?? false} disabled={saving || !settings?.voiceEnabled}
                            onChange={e => void toggle('autoSend', e.target.checked)} className="accent-qteal-600" /> Automatically send transcript
                    </label>
                </div>
                <Model catalog={catalog} settings={settings} downloads={downloads.snapshots} onSelect={speech.refreshDownload}
                    onUse={id => speech.updateSettings({ modelId: id, voiceEnabled: true })}
                    onAction={async (action, id) => {
                        await downloads.run(action, id);
                        if (action === 'remove' && settings?.modelId === id) {
                            await speech.updateSettings({ modelId: null, voiceEnabled: false });
                        }
                    }} />
            </> : speech.loadError ? <div>
                <p role="alert" className="text-sm text-red-700 dark:text-red-300">{speech.loadError}</p>
                <button type="button" className="mt-2 rounded border px-2 py-1 text-sm" onClick={() => void speech.load()}>Retry loading voice models</button>
            </div> : <p role="status" className="text-sm">Loading voice models…</p>}
            {error && <p role="alert" className="text-sm text-red-700 dark:text-red-300">{error}</p>}
            <details className="text-xs text-zinc-600 dark:text-zinc-400">
                <summary className="cursor-pointer">Voice credits and licenses</summary>
                <p className="mt-1">Handy and @handy-computer/models are MIT-licensed. Copyright (c) 2025 CJ Pais.</p>
                <a className="mt-1 inline-block underline" href="/api/speech/credits" download="Quenderin-third-party-notices.txt">Read the third-party notices</a>
            </details>
        </section>
    );
}
