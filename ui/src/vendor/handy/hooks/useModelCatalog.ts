// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/hooks/useModelCatalog.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { useMemo } from "react";
import type { SpeechModelListResponse } from '../../../lib/speech/types.js';
import { makeGrading } from "../lib/models/grading.js";

/** Join the curated catalog to the desktop's installed and benchmark data by id. */
export const useModelCatalog = (catalog: SpeechModelListResponse) => {
  const { models, recommendedModelId, accurateModelId } = catalog;
  return useMemo(() => {
    const byId = new Map(models.map(row => [row.model.id, row]));
    const ids = [
      [recommendedModelId, "pick"],
      [accurateModelId, "accurate"],
    ] as const;
    const picks = ids.flatMap(([id, role]) => {
      const row = id && byId.get(id);
      return row && (role === "pick" || id !== recommendedModelId) ? [{ row, role }] : [];
    });
    return {
      offered: models, picks, grading: makeGrading(models),
      infoFor: (id: string | null) => id ? byId.get(id) : undefined,
    };
  }, [models, recommendedModelId, accurateModelId]);
};
