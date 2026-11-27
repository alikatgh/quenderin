// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/columns.tsx at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import type { Grading } from "../../../lib/models/grading.js";
import { formatModelSize } from "../../../lib/models/catalog.js";
import { GradeChip } from "../GradeChip.js";
import { SpeedBars } from "../SpeedBars.js";
import { gradeBand } from "./rubric.js";
import type { TableModel } from "./context.js";

const columnClass = "px-2 py-2 text-center whitespace-nowrap";
export const Codes = () => <>
  <th scope="col" className={columnClass} title="English accuracy">EN</th>
  <th scope="col" className={columnClass}>SPEED</th>
  <th scope="col" className={columnClass}>SIZE</th>
</>;

export const Values = ({ grading, entry }: { grading: Grading; entry: TableModel }) => {
  const grade = grading.grade(entry.id);
  const wait = grading.wait(entry.id);
  return <>
    <td className={columnClass} title={gradeBand(grade.letter)}>
      <GradeChip letter={grade.letter} label={grade.label} />
    </td>
    <td className={columnClass} title={wait == null ? "Unmeasured" : `${wait.toFixed(2)} s after a 30-second dictation`}>
      <SpeedBars level={grading.speed(entry.id)} />
    </td>
    <td className={`${columnClass} text-xs tabular-nums`}>{formatModelSize(entry.size)}</td>
  </>;
};
