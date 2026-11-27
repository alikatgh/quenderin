// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/rubric.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { GRADE_CEILINGS } from "../../../lib/models/catalog.js";
import type { GradeLetter } from "../GradeChip.js";

export const gradeBand = (letter: GradeLetter): string | undefined => {
  if (letter === "none") return undefined;
  if (letter === "F") return "30% error or higher";
  const letters = Object.keys(GRADE_CEILINGS) as (keyof typeof GRADE_CEILINGS)[];
  const i = letters.indexOf(letter);
  return i ? `${GRADE_CEILINGS[letters[i - 1]]}–${GRADE_CEILINGS[letter]}% error`
    : `Under ${GRADE_CEILINGS[letter]}% error`;
};
