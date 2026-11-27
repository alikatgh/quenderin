// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/tableModel.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { modelFile } from '@handy-computer/models';
import type { SpeechModelSummary } from '../../../../../lib/speech/types.js';
import type { TableModel } from "./context.js";

/** The catalog row as the table shows it. */
export const toTableModel = (row: SpeechModelSummary): TableModel => {
  const { model } = row;
  return {
    id: model.id, name: model.name, description: model.description, languages: model.languages,
    streaming: model.capabilities.streaming, translate: model.capabilities.translate,
    size: modelFile(model).size, license: model.license,
    blocked: row.engine.compatibility !== "supported", onDisk: row.installed, model,
  };
};
