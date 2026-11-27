// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/onboarding/screens/Model.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { useEffect, useId, useRef, useState } from "react";
import { Download } from "lucide-react";
import { useOnboardingModels } from "../useOnboardingModels.js";
import { downloadPick } from "../downloadPick.js";
import { DownloadStatus } from "../DownloadStatus.js";
import { GradeChip } from "../../shared/GradeChip.js";
import { SpeedBars } from "../../shared/SpeedBars.js";
import { Tag } from "../../shared/Tag.js";
import { ModelTable } from "../../shared/modelTable/ModelTable.js";
import { toTableModel } from "../../shared/modelTable/tableModel.js";
import { ROLE_KEYS, sizeOf } from "../../../lib/models/catalog.js";
import type { SpeechDownloadSnapshot, SpeechModelListResponse, SpeechSettings } from '../../../../../lib/speech/types.js';
import { isSpeechDownloadActive } from '../../../../../lib/speech/useSpeechDownload.js';

const button = "rounded-lg px-3 py-2 text-sm font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-qteal-500 disabled:opacity-50";
const primary = `${button} inline-flex items-center gap-2 bg-zinc-900 text-white hover:bg-zinc-800 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white`;
const secondary = `${button} text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800`;
type Action = "start" | "pause" | "resume" | "cancel" | "retry" | "remove";

export function Model({ catalog, downloads, settings, onAction, onUse, onSkip, onFinish, onSelect }: {
  catalog: SpeechModelListResponse;
  downloads: Readonly<Record<string, SpeechDownloadSnapshot>>;
  settings: SpeechSettings | null;
  onAction: (action: Action, id: string) => Promise<void>;
  onUse: (id: string) => Promise<void>;
  onSkip?: () => Promise<void>;
  onFinish?: () => void;
  onSelect?: (id: string) => void;
}) {
  const models = useOnboardingModels(catalog, downloads);
  const [chosen, choose] = useState<string | null>(null);
  const [showAll, setShowAll] = useState(false);
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);
  const group = useId();
  const panel = useRef<HTMLDivElement>(null);
  const allButton = useRef<HTMLButtonElement>(null);
  const selected = models.infoFor(chosen ?? settings?.modelId ?? catalog.recommendedModelId) ?? models.offered[0];
  const id = selected?.model.id;
  const snapshot = id ? downloads[id] : undefined;
  const active = isSpeechDownloadActive(snapshot);
  const blocked = selected?.engine.compatibility !== "supported";
  const enabled = !!id && settings?.voiceEnabled && settings.modelId === id;
  const extra = selected && !models.picks.some(p => p.row.model.id === id) ? selected : undefined;

  function select(id: string) {
    choose(id);
    setError(null);
    setConfirmRemove(null);
  }
  function open(initialQuery = "") {
    setQuery(initialQuery);
    setShowAll(true);
  }
  function close() {
    setShowAll(false);
    allButton.current?.focus();
  }

  useEffect(() => {
    if (id) onSelect?.(id);
  }, [id, onSelect]);

  async function act(operation: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try { await operation(); } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update the voice model. Try again.");
    } finally { setBusy(false); }
  }

  if (!selected) return <p role="status">No speech models are available.</p>;
  return (
    <div ref={panel} className="space-y-3" onKeyDown={event => {
      if (showAll || event.nativeEvent.isComposing || event.ctrlKey || event.altKey || event.metaKey) return;
      if (/^(INPUT|TEXTAREA|SELECT)$/.test((event.target as HTMLElement).tagName)) return;
      if (event.key.length === 1 && event.key !== " ") {
        event.preventDefault();
        open(event.key);
      }
    }}>
      <fieldset disabled={busy} className="space-y-2">
        <legend className="sr-only">Choose a voice model</legend>
        {[...models.picks, ...(extra ? [{ row: extra, role: null }] : [])].map(({ row, role }) => {
          const checked = row.model.id === id;
          return (
            <label key={row.model.id} className={`flex cursor-pointer items-start gap-3 rounded-xl border px-3 py-3 sm:px-4 ${checked ? "border-qteal-600 bg-qteal-50 dark:bg-qteal-600/40" : "border-zinc-200 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"}`}>
              <input type="radio" name={group} checked={checked} onChange={() => select(row.model.id)} className="mt-1 accent-qteal-600" />
              <span className="min-w-0 flex-1">
                <span className="flex flex-wrap items-center gap-2 text-sm font-semibold">
                  {role && <Tag>{ROLE_KEYS[role]}</Tag>}
                  <bdi>{row.model.name}</bdi>
                </span>
                {checked && <span className="mt-1 block text-xs leading-relaxed text-zinc-600 dark:text-zinc-300">{row.model.description}</span>}
                {row.engine.compatibility !== "supported" && <span className="mt-1 block text-xs text-amber-800 dark:text-amber-300">Needs newer speech engine</span>}
              </span>
              <span className="flex shrink-0 flex-col items-end gap-1 text-xs tabular-nums">
                <bdi>{sizeOf(row.model)}</bdi>
                <span className="flex items-center gap-2">
                  <GradeChip {...row.englishGrade} dense />
                  <SpeedBars level={row.speedLevel} />
                </span>
              </span>
            </label>
          );
        })}
      </fieldset>
      <button ref={allButton} type="button" aria-expanded={showAll} className={secondary}
        onClick={() => showAll ? close() : open()}>{showAll ? "Hide all models" : `Show all ${models.offered.length} models`}</button>
      {showAll && <ModelTable grading={models.grading} entries={models.offered.map(toTableModel)} selectedId={id ?? null}
        choose={select} onEscape={close} initialQuery={query} roleFor={key => models.picks.find(p => p.row.model.id === key)?.role} />}
      {snapshot && <DownloadStatus name={selected.model.name} snapshot={snapshot} />}
      {error && <p role="alert" className="text-sm text-red-700 dark:text-red-300">{error}</p>}
      <div className="flex flex-wrap items-center gap-2">
        {!selected.installed && !active && snapshot?.phase !== "paused" && snapshot?.phase !== "error" && (
          <button type="button" className={primary} disabled={busy || blocked} onClick={() => void act(async () => {
            if (await downloadPick(models, selected.model.id, settings?.modelId ?? null,
              target => onAction("start", target), target => onAction("cancel", target))) await onUse(selected.model.id);
          })}><Download aria-hidden="true" className="size-4" />Download {sizeOf(selected.model)}</button>
        )}
        {selected.installed && !enabled && <button type="button" className={primary} disabled={busy || blocked}
          onClick={() => void act(() => onUse(selected.model.id))}>Use this model</button>}
        {active && <button type="button" className={secondary} disabled={busy}
          onClick={() => void act(() => onAction("pause", selected.model.id))}>Pause</button>}
        {(snapshot?.phase === "paused" || snapshot?.phase === "error") && <button type="button" className={primary} disabled={busy || blocked}
          onClick={() => void act(async () => {
            await onAction(snapshot.phase === "paused" ? "resume" : "retry", selected.model.id);
            if (!enabled) await onUse(selected.model.id);
          })}>{snapshot.phase === "paused" ? "Resume" : "Retry"}</button>}
        {(active || snapshot?.phase === "paused" || snapshot?.phase === "error") && <button type="button" className={secondary} disabled={busy}
          onClick={() => void act(() => onAction("cancel", selected.model.id))}>Cancel download</button>}
        {!onSkip && selected.installed && (confirmRemove === id
          ? <><button type="button" className={secondary} disabled={busy} onClick={() => void act(async () => {
            await onAction("remove", selected.model.id);
            setConfirmRemove(null);
          })}>Confirm removal</button><button type="button" className={secondary} onClick={() => setConfirmRemove(null)}>Keep model</button></>
          : <button type="button" className={secondary} disabled={busy} onClick={() => setConfirmRemove(selected.model.id)}>Remove model</button>)}
        {onFinish && enabled && (active || selected.installed) && <button type="button" className={primary}
          disabled={busy} onClick={onFinish}>Finish setup</button>}
        {onSkip && <button type="button" className={secondary} disabled={busy} onClick={() => void act(onSkip)}>Skip — I’ll type</button>}
      </div>
      {onFinish && !selected.installed && <p className="text-xs text-zinc-600 dark:text-zinc-400">Downloads while you finish setup</p>}
    </div>
  );
}
