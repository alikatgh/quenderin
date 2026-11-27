// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/GradeChip.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import React from "react";

export type GradeLetter = "A" | "B" | "C" | "D" | "F" | "none";

interface GradeChipProps {
  letter: GradeLetter;
  /** What the chip says: "A+", "B−", or "—" / "?" when there's no grade. */
  label: string;
  /** Narrow, for past five languages in a row of columns. */
  dense?: boolean;
}

// Each letter's full class set, so no two classes compete for a property.
const LETTER_CLASSES: Record<GradeLetter, string> = {
  A: "text-white font-bold border-transparent bg-zinc-800 dark:bg-zinc-100 dark:text-zinc-900",
  B: "font-bold border-transparent bg-zinc-200 dark:bg-zinc-700",
  C: "font-bold bg-transparent border-zinc-500",
  D: "font-bold bg-transparent border-dashed border-zinc-500",
  F: "font-bold bg-transparent border-transparent",
  none: "text-zinc-600 dark:text-zinc-400 font-medium bg-transparent border-transparent",
};

/** A model's accuracy grade for one language. */
export const GradeChip: React.FC<GradeChipProps> = ({
  letter,
  label,
  dense = false,
}) => (
  <span
    className={`inline-grid place-items-center rounded-md border  leading-none h-[22px] ${dense ? "min-w-[24px] px-[3px] text-xs" : "min-w-[30px] px-[5px] text-xs"} ${LETTER_CLASSES[letter]}`}
  >
    {/* Trim to cap height so the letter, is centered. */}
    <span className="block [text-box:trim-both_cap_alphabetic]"><bdi>{label}</bdi></span>
  </span>
);
