# The WhatsApp shell, the model router, and deep settings

Direction set by the owner 2026-07-03: (1) WhatsApp-style navigation where everything has a
dedicated page, (2) let storage-rich users download ALL models and have the system pick the
right one per task, (3) deeply customizable settings. This doc is the plan + live status.

## 1. Shell — WhatsApp anatomy

**macOS (shipped):** a fixed 64pt icon RAIL (Chats / Agent / Model library, Settings gear at
the foot) · list column · detail. `MacRootView.railColumn`; selection reads through color
only. ⌘N from any rail section lands in the empty chat. The gear opens the standard ⌘,
Settings scene (Mac idiom beats WhatsApp idiom for preferences).

**iOS (shipped):** the tab bar gains a Models tab (same shared `ModelsLibraryView`).

**Android (open — parity chip):** bottom nav gains Models; same shared anatomy.

**Also shipped (same-day polish round):** live download badge on the Models rail item
(count + progress ring; downloads survive navigation — the library controller is shared,
not per-view) · sequential bulk download (first model usable while the rest arrive) ·
drag-a-.gguf-onto-the-library import (catalog-matching files only, magic-checked, never
silently hoards disk) · Agent page identity header + structured numbered run log ·
vendor-logo avatars everywhere.

**Later, in the same spirit:** Archived chats · Starred messages (both cheap on the existing
conversation index).

## 2. Model library + router

**Library page (shipped, `ModelsLibraryView`):** whole catalog with per-model state
(installed / progress / failed-retry), live storage meter, per-row fit badges, and the
2 TB-owner move — "Download the complete library (N GB)" appears ONLY when everything
missing fits with ≥10 GB of disk left over. Library downloads go through the same
integrity gate as onboarding installs (corrupt file → deleted, never listed).

**Router (shipped, `ModelRouter` Swift + Kotlin twins):** classify the prompt
(coding / reasoning / multilingual / general — plain substring & code-point scans, NO
regex: that's where Swift↔Kotlin silently diverge), then pick the largest installed model
of the task's preferred family that fits RAM right now. Every decision carries a
human-readable reason. Classification contract pinned by `shared/router-parity-vectors.json`
+ `scripts/check_router_parity.py` (CI; namespace-split from the agent vectors — ids start
`router-`).

**Surfacing (shipped, iOS/macOS):** while drafting the FIRST message of a chat, if the
router's pick differs from the loaded model, a chip above the composer offers it
("a coding question — Qwen2.5 Coder 7B is the best fit you have installed · Switch").
One tap switches (draft survives); ✕ dismisses. **Never a silent mid-conversation swap** —
that would re-prefill the transcript on another model behind the user's back.

**Open:**
- Full-auto mode (route + switch + send in one flow) — needs send-after-load orchestration
  through `OnboardingModel`'s phases; the chip is the honest v1.
- Router v2: use the small resident model as a classifier when heuristics are unsure.
- Android UI wiring (core `ModelRouter.kt` + CoreVerify checks already landed).

## 3. Settings

**Shipped (`AppSettings`, UserDefaults-backed, every default = previous behavior):**
- Appearance pane: Theme (System/Light/Dark), Chat font (System/Serif/Monospaced),
  Text size (4 steps) — applied via the transcript's font environment.
- Routing: "Suggest the best model for each task" toggle.

**Rule (from the bug journal):** a setting ships only when something reads it — no
advertised-but-unimplemented toggles.

**Open, roughly in order:**
- Chat pane: Enter-vs-⌘Enter to send, auto-title on/off, history retention.
- Advanced engine knobs behind a disclosure: context length, thread count, GPU offload
  (Android), deep-thinking default.
- Per-task routing pins ("coding → always Qwen2.5 Coder").
- Android settings store twin (DataStore) + the same panes.

## Verification state (2026-07-03)

225 tests green (router behavior + 10-vector classification parity on both platforms, both
parity scripts green); Mac app built and driven live: rail navigation, Models library with
real disk numbers (the download-all gate correctly hidden on a 5 GB-free machine), the
Appearance pane rendering, chat regression-free with the teal palette.
