// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/Tag.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import React from "react";

/** A small rounded word beside a name ("Recommended", "Old format"). */
export const Tag: React.FC<React.HTMLAttributes<HTMLSpanElement>> = ({
  className = "",
  ...props
}) => (
  <span
    className={`shrink-0 whitespace-nowrap rounded-full border px-[7px] text-xs leading-[17px] font-semibold border-zinc-300 dark:border-zinc-600 text-zinc-700 dark:text-zinc-300 ${className}`}
    {...props}
  />
);
