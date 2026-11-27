import type { SpeechSpeedLevel } from '../../lib/speech/types.js';

/**
 * Handy's wait cutoffs, in seconds: four bars under 2 s, three under 3.5 s,
 * two under 7.5 s, one under 20 s, none at or above 20 s.
 * Ported verbatim from Handy src/components/shared/SpeedBars.tsx.
 */
export const SPEED_CUTOFFS = [2, 3.5, 7.5, 20] as const;

export interface SpeedBarsProps {
    /** 0–4 bars, computed by the backend from the measured wait. */
    readonly level: SpeechSpeedLevel;
    readonly className?: string;
}

/** Four ascending bars filled to the model's speed level. */
export function SpeedBars(_props: SpeedBarsProps): JSX.Element {
    throw new Error('TODO(stage2): render four bars, filled up to `level`, with an accessible text equivalent.');
}
