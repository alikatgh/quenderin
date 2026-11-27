// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/lib/models/catalog.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { formatBinarySize, modelFile, type CatalogModel } from '@handy-computer/models';

export type PickRole = "pick" | "accurate";
export const ROLE_KEYS: Record<PickRole, string> = {
  pick: "Recommended",
  accurate: "More accurate",
};

export const GRADE_CEILINGS = { A: 5, B: 10, C: 20, D: 30 } as const;

// Handy uses binary units but labels them MB and GB on its onboarding screen.
export const formatModelSize = (bytes: number) => formatBinarySize(bytes).replace(/iB$/, "B");
export const sizeOf = (model: CatalogModel) => formatModelSize(modelFile(model).size);
