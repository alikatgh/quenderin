# r15 — Quenderin auth-session audit (2026-07-11)

**Lens:** Token storage, session invalidation, gate coverage (50-round plan r15)
**Mode:** Inline audit (Claude). **Verdict: clean — no fixes required.** The r9-flagged Electron
hotkey gap was already fixed upstream (`src/electron/main.ts:128`, Q-008).

## Verified

1. **Gate coverage** (`src/app.ts:100-126`): ALL mutating `/api/*` methods + user-data GET
   prefixes (`/api/sessions`, `/api/notes`, `/api/memory`, `/diagnostics`, `/api/metrics`,
   `/api/agent`, `/api/tasks`) require the per-launch token; empty token fails closed. The new
   `POST /api/models/switch` path is covered by the mutating rule. Public GETs (health, catalog,
   presets, tools, templates, docs) are deliberate and documented inline.
2. **Compare is timing-safe** (`src/security/authToken.ts:39` → `timingSafeEqualStr`).
3. **Token delivery**: Electron preload (out-of-band) or `?token=` opened-URL; the renderer reads
   it ONCE and strips it from the address bar/history (Q-525); `errorHandler` strips `?token=`
   from logged URLs (Q-355); missing token shows the reconnect banner instead of opaque 401s (Q-526).
4. **WS**: upgrade validates the token; origin gate enforced (`ws-origin-gate.test.ts`); approval
   flows fail closed when the approving socket disconnects.
5. **Public docs route** (`src/routes/docs.ts`): default-deny allowlist + `path.basename` +
   `.md`-only — no traversal surface.
6. **Bind**: loopback by default (`QUENDERIN_HOST` opt-out is explicit and commented).

## Open / notes
- Per-launch token never rotates during a run — acceptable for a localhost single-user app;
  revisit only if the LAN-exposure flag becomes a supported mode (pair with r26 rate-limiting).
- Tests already pin the contract: `auth-token.test.ts`, `app-read-auth.test.ts`,
  `has-auth-token.test.ts`, `ws-origin-gate.test.ts`.
