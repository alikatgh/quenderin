import type { SpeechGradeLetter } from '../../lib/speech/types.js';

export interface GradeChipProps {
    readonly letter: SpeechGradeLetter;
    /** What the chip says: "A+", "B−", "—" (unsupported) or "?" (unmeasured). */
    readonly label: string;
    /** Narrow variant for dense language columns. */
    readonly dense?: boolean;
}

/**
 * One model's accuracy grade for English, styled like Handy's GradeChip:
 * A/B/C/D/F letters, with the label carrying the +/- modifier.
 */
export function GradeChip(_props: GradeChipProps): JSX.Element {
    throw new Error('TODO(stage2): render the grade chip with an accessible label and Handy band styling.');
}
