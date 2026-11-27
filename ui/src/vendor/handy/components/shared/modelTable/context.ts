// SPDX-License-Identifier: MIT
// Copyright (c) 2025 CJ Pais
// Adapted from Handy src/components/shared/modelTable/context.ts at 05efc5fc180197dc0fa9d568dd9812904b723b8b.
// See THIRD_PARTY_NOTICES.md.
import { createContext, useContext } from "react";
import type { Grading } from "../../../lib/models/grading.js";
import type { CatalogModel } from '@handy-computer/models';

export interface TableModel {
  id: string;
  name: string;
  description: string;
  languages: readonly string[];
  streaming: boolean;
  translate: boolean;
  size: number;
  license: string;
  blocked: boolean;
  onDisk: boolean;
  model: CatalogModel;
}

export const ModelTableContext = createContext<{ grading: Grading } | null>(null);
export const useModelTable = () => {
  const ctx = useContext(ModelTableContext);
  if (!ctx) throw new Error("A model row must be inside a ModelTable");
  return ctx;
};
