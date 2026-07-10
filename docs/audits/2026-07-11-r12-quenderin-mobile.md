# r12 — Quenderin mobile audit (2026-07-11)

**Lens:** Responsive dashboard + native parity (50-round plan r12)
**Mode:** Inline audit + same-session fixes; responsive checks run live at 375×812.

## Responsive dashboard

### M1 — Model Manager rows collided at phone width — **FIXED** (Medium)
- **File:** `ui/src/components/SettingsArea.tsx` (model row)
- **Symptom:** At 375px the fixed `flex items-center` row forced info + actions side-by-side;
  the metadata line ("13.2 GB download", quant chip) rendered UNDER/through the Download button.
- **Fix:** `flex-col sm:flex-row` (actions stack below info on phones) + `flex-wrap` on the
  metadata line. Verified by screenshot at 375×812 — clean stacking, no overlap.

### Verified good
- No horizontal overflow (`scrollWidth == clientWidth == 375`) on Chat, Tasks, Metrics, Settings.
- Sidebar/Inspector are proper mobile drawers (`fixed inset-y-0`, translate-off-screen, hamburger
  with `aria-label`); Metrics table scrolls inside its own `overflow-x-auto` container.

## Native parity (the other half of this lens)
- Swift/Kotlin twins are covered by standing infrastructure rather than this round: agent vectors
  19×3 (`check_agent_parity.py`), router 10×2, catalog 13×4, safety 34×3, sampling profiles — all
  enforced in CI (see r7-wave work and `docs/audits/2026-07-08-agent-loop-parity.md`).
- Expo/RN gaps: N/A — the abandoned `mobile/` RN scaffold was removed (68d8d49); `off-grid-mobile`
  is a separate product with its own repo-level tooling and is out of this plan's per-round scope.
