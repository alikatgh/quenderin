// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/lib/models/downloadState.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import type { SpeechDownloadSnapshot } from '../../../../lib/speech/types.js';

export const downloadStateOf = (p: SpeechDownloadSnapshot | undefined) => {
  switch (p?.phase) {
    case "verifying": return { state: "checking" } as const;
    case "downloading": return {
      state: "downloading", progress: p.percent / 100, etaSeconds: p.etaSeconds,
      downloaded: p.downloadedBytes, total: p.totalBytes, bytesPerSec: p.bytesPerSecond,
    } as const;
    case "installed": return { state: "ready" } as const;
    case "error": return { state: "failed" } as const;
    case "paused": return { state: "paused" } as const;
    case "queued": return { state: "queued" } as const;
    default: return { state: "none" } as const;
  }
};
