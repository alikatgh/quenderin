// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/onboarding/DownloadStatus.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { ProgressRing } from "../shared/ProgressRing.js";
import { formatModelSize } from "../../lib/models/catalog.js";
import { downloadStateOf } from "../../lib/models/downloadState.js";
import type { SpeechDownloadSnapshot } from '../../../../lib/speech/types.js';

export const DownloadStatus = ({ name, snapshot }: { name: string; snapshot: SpeechDownloadSnapshot }) => {
  const d = downloadStateOf(snapshot);
  if (d.state === "none") return null;
  const percent = Math.min(99, Math.floor(snapshot.percent));
  const state = {
    downloading: "Downloading", checking: "Verifying", failed: "Download stopped",
    paused: "Paused", queued: "Queued", ready: "Ready",
  }[d.state];
  return (
    <div className="flex min-w-0 items-center gap-2 text-start text-xs">
      {d.state === "downloading" || d.state === "checking" ? <ProgressRing value={d.state === "checking" ? 1 : d.progress} size={20} /> : null}
      <div className="min-w-0">
        <div role="status" className="font-medium">{state} · {name}</div>
        {(d.state === "downloading" || d.state === "paused" || d.state === "checking") && <>
          <progress className="sr-only" aria-label={`${name} download progress`} max={100} value={d.state === "checking" ? 100 : percent} />
          <div className="tabular-nums text-zinc-600 dark:text-zinc-400">
            {d.state === "checking" ? "Checking the file’s SHA-256." : `${percent}% · ${formatModelSize(snapshot.downloadedBytes)} of ${formatModelSize(snapshot.totalBytes)}`}
          </div>
        </>}
        {snapshot.error && <p role="alert" className="text-red-700 dark:text-red-300">{snapshot.error.message}</p>}
      </div>
    </div>
  );
};
