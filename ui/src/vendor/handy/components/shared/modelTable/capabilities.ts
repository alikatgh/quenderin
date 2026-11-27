// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/capabilities.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { Languages, Radio as LiveIcon } from "lucide-react";

/**
 * What a model can do besides transcribe: its icon, and its flag on a table
 * model and in the catalog's `capabilities`. Words under `modelTable.tags`.
 */
export const CAPABILITIES = {
  preview: { Icon: LiveIcon, flag: "streaming" },
  translate: { Icon: Languages, flag: "translate" },
} as const;

export type Capability = keyof typeof CAPABILITIES;

export const CAPABILITY_KEYS = Object.keys(CAPABILITIES) as Capability[];
