// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/onboarding/downloadPick.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import type { useOnboardingModels } from "./useOnboardingModels.js";

type Models = ReturnType<typeof useOnboardingModels>;

/** A new selection replaces the previous download; an installed model is ready to use. */
export const downloadPick = async (
  models: Models, id: string, downloadId: string | null,
  download: (id: string) => Promise<void>, cancel: (id: string) => Promise<void>,
) => {
  const info = models.infoFor(id);
  if (!info || info.engine.compatibility !== "supported") return false;
  const previous = models.infoFor(downloadId);
  if (previous && previous.model.id !== id &&
      ["downloading", "checking", "queued"].includes(models.downloadState(previous.model.id).state)) {
    await cancel(previous.model.id);
  }
  if (!info.installed) await download(id);
  return true;
};
