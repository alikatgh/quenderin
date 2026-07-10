# r21 — Quenderin security re-pass (2026-07-11)

**Lens:** Second security pass — re-verify June (r1/r5) + consolidated criticals against current
main, with STILL-PRESENT markers. **Verdict: every security-class item from the June wave is
FIXED on main; nothing STILL-PRESENT.**

| June finding | Status on main |
|---|---|
| C1 bind all interfaces | ✅ Fixed — loopback default, env opt-out (`server.ts:42`) |
| C2 vulnerable deps, no CI gate | ✅ Fixed — `npm audit --audit-level=high` in CI + Dependabot (Wave C-adjacent, r8 R5) |
| C3 unverified GGUF downloads | ✅ Fixed — every catalog model pins sha256; verified in CI (`check_catalog_parity`); sideloads namespaced + verified |
| H1 adb shell injection | ✅ Fixed — metacharacter escaping + `%s` space token (`android.provider.ts:185`) |
| H2 5-word blocklist | ✅ Fixed — 34-keyword shared blocklist, 3-platform parity-checked, Unicode-safe tokenizer (this session) |
| H3 no download integrity | ✅ Fixed — `modelIntegrity.ts` stream-hash verify |
| H4 read_file home exposure | ✅ Fixed — home containment + sensitive-store denylist (`handlers.ts:30-62`) |
| H5 SECURITY.md false claims | ✅ Fixed — rewritten (r7 re-verified accurate) |
| H19 WS upgrade on any path | ✅ Fixed — `path: '/ws'` + origin gate + token on upgrade |
| H22 blocklist as only gate | ✅ Superseded — blocklist is now defense-in-depth UNDER consent + per-run approval + mission gate + ledger (Q-549) |

New-code sweep (post-June surface): models/switch validates catalog+disk behind the mutating-token
gate; Autopilot/mission-approval flows fail closed (journal-pinned); WS `maxPayload` + `nosniff`
added this wave (r20/r40). No new security findings.
