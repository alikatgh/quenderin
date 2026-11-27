import type {
    SpeechDownloadSnapshot,
    SpeechModelListResponse,
    SpeechSettings,
    UpdateSpeechSettingsRequest,
} from '../../lib/speech/types.js';

export interface VoiceModelStepProps {
    /** GET /api/speech/models: recommended + accurate ids, all rows, methodology. */
    readonly catalog: SpeechModelListResponse;
    readonly settings: SpeechSettings | null;
    readonly selectedModelId: string | null;
    readonly download: SpeechDownloadSnapshot | null;
    readonly onSelectModel: (modelId: string | null) => void;
    readonly onStartDownload: (modelId: string) => void;
    readonly onPauseDownload: () => void;
    readonly onResumeDownload: () => void;
    readonly onCancelDownload: () => void;
    readonly onRetryDownload: () => void;
    readonly onSkip: () => void;
    readonly onSettingsChange?: (patch: UpdateSpeechSettingsRequest) => void;
}

/**
 * Onboarding step 2 (optional): "Talk to your local model by voice".
 *
 * Layout, modelled on Handy's Model screen:
 *   - Recommended card: catalog.recommendedModelId (Parakeet Unified English 0.6B).
 *   - More accurate card: catalog.accurateModelId (Qwen3-ASR 1.7B).
 *   - "Show all ${catalog.models.length} models" expands SpeechModelTable.
 *   - Primary button: "Download {size}" + "Downloads while you finish setup".
 *   - Secondary: "Skip — I'll type" (voice off, step is skippable).
 *
 * Sizes are the Q8_0 byte counts formatted like Handy (MiB → "697 MB",
 * GiB → "2.0 GB"), never hard-coded strings.
 */
export function VoiceModelStep(_props: VoiceModelStepProps): JSX.Element {
    throw new Error('TODO(stage2): render recommended/accurate cards, full table, download controls and skip path.');
}
