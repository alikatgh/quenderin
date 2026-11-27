import type { SpeechModelSummary } from '../../lib/speech/types.js';

export interface SpeechModelTableProps {
    /** All 29 curated ASR rows; the count in "Show all N" derives from this length. */
    readonly models: readonly SpeechModelSummary[];
    readonly selectedModelId: string | null;
    readonly onSelect: (modelId: string) => void;
    /** Optional initial search text (e.g. typing on the step opens the list). */
    readonly initialQuery?: string;
}

/**
 * Searchable table of every curated ASR model.
 *
 * Columns: model name (+ description), EN grade chip, SPEED bars, SIZE.
 * Filters: Live preview (capabilities.streaming) and Translates
 * (capabilities.translate). Unsupported engines stay visible with the
 * "Needs newer speech engine" note and a disabled row action.
 *
 * The row count, ids, grades and sizes all come from the API payload: nothing
 * about the 29 models is hard-coded here.
 */
export function SpeechModelTable(_props: SpeechModelTableProps): JSX.Element {
    throw new Error('TODO(stage2): render search, capability filters, columns and row selection.');
}
