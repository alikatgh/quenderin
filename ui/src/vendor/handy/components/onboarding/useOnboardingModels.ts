// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/onboarding/useOnboardingModels.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { useModelCatalog } from "../../hooks/useModelCatalog.js";
import { downloadStateOf } from "../../lib/models/downloadState.js";
import type { SpeechDownloadSnapshot, SpeechModelListResponse } from '../../../../lib/speech/types.js';

export const useOnboardingModels = (
  catalog: SpeechModelListResponse, downloads: Readonly<Record<string, SpeechDownloadSnapshot>>,
) => ({
  ...useModelCatalog(catalog),
  downloadState: (id: string) => downloadStateOf(downloads[id]),
});
