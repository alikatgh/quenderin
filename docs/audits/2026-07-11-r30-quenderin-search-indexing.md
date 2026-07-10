# r30 — Search/indexing audit (2026-07-11)

**Verdict: clean — minimal surface.** There is no server-side search endpoint and no SQL/index:
- Desktop model filtering is client-side over the static 13-model catalog.
- The open-catalog search (Apple, `HuggingFaceModelSearch.swift:250`) builds its query with
  `URLComponents.queryItems` — properly percent-encoded, no string-concatenated URLs; results are
  namespaced on disk (`repoSlug__filename`, journaled) and sha-verified where pinned.
- Chat history search: none (sessions listed by recency only).
