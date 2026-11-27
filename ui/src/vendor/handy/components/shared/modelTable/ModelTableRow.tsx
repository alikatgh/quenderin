// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/ModelTableRow.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import type { ReactNode } from "react";
import { CAPABILITIES, CAPABILITY_KEYS } from "./capabilities.js";
import { Values } from "./columns.js";
import { useModelTable, type TableModel } from "./context.js";
import { Tag } from "../Tag.js";
import { ROLE_KEYS, type PickRole } from "../../../lib/models/catalog.js";

export const ModelTableRow = ({ entry, selected, onActivate, role, mark }: {
  entry: TableModel;
  selected: boolean;
  onActivate: () => void;
  role?: PickRole;
  mark?: ReactNode;
}) => {
  const { grading } = useModelTable();
  const capabilities = CAPABILITY_KEYS.filter(c => entry[CAPABILITIES[c].flag]);
  return (
    <tr className={selected ? "bg-qteal-50 dark:bg-qteal-900/25" : "hover:bg-zinc-100 dark:hover:bg-zinc-800/70"}>
      <td className="border-t border-zinc-200 px-3 py-2 dark:border-zinc-800">
        <button type="button" data-model-row={entry.id} aria-pressed={selected} onClick={onActivate}
          className="flex w-full items-start gap-2 rounded text-start focus-visible:outline focus-visible:outline-2 focus-visible:outline-qteal-500">
          <span aria-hidden="true" className={`mt-0.5 grid size-4 shrink-0 place-items-center rounded-full border ${selected ? "border-qteal-600 text-qteal-700 dark:text-qteal-300" : "border-zinc-400"}`}>{mark ?? (selected ? "•" : "")}</span>
          <span className="min-w-0">
            <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm font-semibold">
              {entry.name}
              {role && <Tag>{ROLE_KEYS[role]}</Tag>}
              {capabilities.map(c => {
                const { Icon } = CAPABILITIES[c];
                return <Icon key={c} role="img" aria-label={c === "preview" ? "Live preview" : "Translates"} className="size-3.5" />;
              })}
            </span>
            <span className="mt-0.5 block text-xs text-zinc-600 dark:text-zinc-400">{entry.description}</span>
            <span className="mt-1 block text-xs text-zinc-600 dark:text-zinc-400">License {entry.license}{entry.onDisk ? " · Installed" : ""}</span>
            {entry.blocked && <span className="text-xs font-medium text-amber-800 dark:text-amber-300">Needs newer speech engine</span>}
          </span>
        </button>
      </td>
      <Values grading={grading} entry={entry} />
    </tr>
  );
};
