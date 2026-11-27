// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/ModelTable.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { useEffect, useId, useRef, useState } from "react";
import { catalogModelSearchText, displayLanguage } from '@handy-computer/models';
import { Search } from "lucide-react";
import { CAPABILITIES, CAPABILITY_KEYS, type Capability } from "./capabilities.js";
import { Codes } from "./columns.js";
import { ModelTableContext, type TableModel } from "./context.js";
import { ScrollThumb } from "./ScrollThumb.js";
import { ModelTableRow } from "./ModelTableRow.js";
import type { Grading } from "../../../lib/models/grading.js";
import type { PickRole } from "../../../lib/models/catalog.js";

type Filters = { query: string } & Record<Capability, boolean>;
const NO_FILTERS: Filters = { query: "", preview: false, translate: false };
const labels: Record<Capability, string> = { preview: "Live preview", translate: "Translates" };

const useModelFilters = (query: string) => {
  const [filters, setFilters] = useState<Filters>({ ...NO_FILTERS, query });
  const q = filters.query.trim().toLowerCase();
  const matches = (e: TableModel) => {
    const has = (c: Capability) => e[CAPABILITIES[c].flag];
    if (CAPABILITY_KEYS.some(c => filters[c] && !has(c))) return false;
    if (!q) return true;
    const hay = [catalogModelSearchText(e.model), e.description,
      ...CAPABILITY_KEYS.filter(has).map(c => labels[c]), ...e.languages.map(displayLanguage),
    ].join(" ").toLowerCase();
    return q.split(/\s+/).every(word => hay.includes(word));
  };
  return { filters, setFilters, matches };
};

export const ModelTable = ({ grading, entries, selectedId, choose, onEscape, initialQuery, roleFor }: {
  grading: Grading;
  entries: readonly TableModel[];
  selectedId: string | null;
  choose: (id: string) => void;
  onEscape: () => void;
  initialQuery: string;
  roleFor: (id: string) => PickRole | undefined;
}) => {
  const { filters, setFilters, matches } = useModelFilters(initialQuery);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const title = useId();
  const rows = entries.filter(matches);

  useEffect(() => { searchRef.current?.focus({ preventScroll: true }); }, []);

  return (
    <section aria-labelledby={title}
      onKeyDown={event => {
        if (event.nativeEvent.isComposing) return;
        if (event.key === "Escape") {
          event.preventDefault();
          if (filters.query) setFilters(f => ({ ...f, query: "" }));
          else onEscape();
        }
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          const buttons = [...(listRef.current?.querySelectorAll<HTMLButtonElement>("[data-model-row]") ?? [])];
          const step = event.key === "ArrowDown" ? 1 : -1;
          const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
          const next = index < 0 && step < 0 ? buttons.at(-1) : buttons[index + step];
          if (next || index === 0) {
            event.preventDefault();
            (next ?? searchRef.current)?.focus();
          }
        }
      }}
      className="rounded-lg border border-zinc-200 dark:border-zinc-700">
      <h3 id={title} className="sr-only">Speech models</h3>
      <div className="flex flex-wrap items-center gap-3 p-3">
        <label className="flex min-w-40 flex-1 items-center gap-2 rounded border border-zinc-300 px-2 dark:border-zinc-600">
          <Search aria-hidden="true" className="size-4 text-zinc-500" />
          <input ref={searchRef} type="search" aria-label="Search models" value={filters.query}
            onChange={event => setFilters(f => ({ ...f, query: event.target.value }))}
            placeholder="Search models" className="w-full bg-transparent py-1.5 text-sm" />
        </label>
        {CAPABILITY_KEYS.map(key => (
          <label key={key} className="inline-flex cursor-pointer items-center gap-1.5 text-xs font-medium">
            <input type="checkbox" checked={filters[key]} className="accent-qteal-600"
              onChange={event => setFilters(f => ({ ...f, [key]: event.target.checked }))} />
            {labels[key]}
          </label>
        ))}
      </div>
      <div className="relative group/scroll">
        <div ref={listRef} className="max-h-64 overflow-auto [scrollbar-width:none]">
          <ModelTableContext.Provider value={{ grading }}>
            <table className="w-full text-start">
              <thead className="sticky top-0 z-[1] bg-zinc-100 text-[11px] text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
                <tr><th scope="col" className="px-3 py-2 text-start">MODEL</th><Codes /></tr>
              </thead>
              <tbody>
                {rows.map(entry => <ModelTableRow key={entry.id} entry={entry} selected={entry.id === selectedId}
                  onActivate={() => choose(entry.id)} role={roleFor(entry.id)} />)}
              </tbody>
            </table>
          </ModelTableContext.Provider>
          {!rows.length && <p role="status" className="px-3 py-4 text-sm">No models match your search.</p>}
        </div>
        <ScrollThumb listRef={listRef} />
      </div>
    </section>
  );
};
