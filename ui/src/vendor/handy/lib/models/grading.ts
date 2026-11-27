// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/lib/models/grading.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import type { SpeechModelSummary } from '../../../../lib/speech/types.js';

/** The server binds Handy's grade and wait to the curated row. */
export const makeGrading = (rows: readonly SpeechModelSummary[]) => {
  const byId = new Map(rows.map(row => [row.model.id, row]));
  return {
    grade: (id: string) => byId.get(id)?.englishGrade ?? { letter: "none", label: "?" } as const,
    speed: (id: string) => byId.get(id)?.speedLevel ?? 0,
    wait: (id: string) => byId.get(id)?.waitSeconds,
  };
};
export type Grading = ReturnType<typeof makeGrading>;
