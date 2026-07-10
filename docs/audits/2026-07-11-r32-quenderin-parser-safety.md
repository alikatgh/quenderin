# r32 — Parser-safety audit (2026-07-11)

**Verdict: clean.**
- **XML** (device UI dumps — untrusted): `fast-xml-parser` with `processEntities: false`
  (H34 fix holds, `uiParser.service.ts:39`) — no entity expansion (billion-laughs) surface.
- **JSON**: model output goes through `firstJsonObject` (balanced-brace scan, H13-guarded,
  single shared implementation since this session) then `JSON.parse` inside try; WS input capped
  at 16 MiB frame / field-level slices; REST at 256 kB.
- **GBNF grammar**: schemas are shaped oneOf-per-variant and smoke-tested against the real engine
  (`scripts/smoke_llm_engine.ts`) — the journaled every-property-emitted trap is pinned.
- **Markdown** (chat render): `safeMarkdownComponents` restricts elements; CSP blocks scripts.
