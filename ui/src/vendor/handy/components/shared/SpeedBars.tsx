// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/SpeedBars.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import React from "react";

const HEIGHTS = ["h-[5px]", "h-[8px]", "h-[11px]", "h-[14px]"];

interface SpeedBarsProps {
  level: number;
  className?: string;
}

/** Four bars filled up to the model's speed level. */
export const SpeedBars: React.FC<SpeedBarsProps> = ({
  level,
  className = "",
}) => (
  <span dir="ltr" role="img" aria-label={`Speed ${level} of 4`} className={`inline-flex items-end gap-[2px] h-[14px] ${className}`}>
    {HEIGHTS.map((height, i) => (
      <i
        key={i}
        className={`w-[4px] rounded-[1px] ${height} ${i < level ? "bg-qteal-600 dark:bg-qteal-400" : "bg-zinc-200 dark:bg-zinc-700"}`}
      />
    ))}
  </span>
);
