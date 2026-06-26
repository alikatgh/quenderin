# Ship readiness — native iOS + Android

**One-line truth:** everything that can be done **in software** is done and green. What remains
to put these apps *in the stores* requires **your accounts, your hardware, and your legal/contact
details** — an agent cannot create an Apple Developer account, host a URL, sign a build, or hold
a physical phone. This file is the exact, deduplicated list of those items, each reduced to the
smallest action.

Last reconciled: 2026-06-20 (against `main`). Sources: `docs/audits/2026-06-16-store-compliance-audit.md`,
`LAUNCH_CHECKLIST.md`, current source.

---

## ✅ Software-complete (verifiable now — no human needed)

| Area | State | Verify |
|------|-------|--------|
| iOS brain + UI (M1–M4, picker, chat with history, agent, Settings, model switching) | done | `cd apple/QuenderinKit && swift test` → **153 tests** |
| Android brain (M1–M4, picker) + app module (Compose) | done | core: `kotlinc … CoreVerify.kt` → **all checks**; app: `cd android && ./gradlew :app:assembleDebug` |
| Real on-device inference (iOS xcframework / Android `jni/llama.cpp`) | proven both platforms | `apple/verify-llama-link.sh`, `android/verify-llama-link.sh` |
| Catalog parity across 3 platforms | enforced | `npm run check:catalog-parity` |
| **Gen-AI content safety** — disclaimer, Report affordance (chat+agent), agent answer/tool gate, **chat-output flag** (`ChatMessage.isFlagged`), agent **halt-reason** copy | done + parity-checked | covered by the suites above |
| iOS `PrivacyInfo.xcprivacy` (required-reason APIs) | added | in `apple/` |
| Android FGS `<service foregroundServiceType="dataSync">` (was an API-34 crash) | added | in `AndroidManifest.xml` |
| `ITSAppUsesNonExemptEncryption=false`, `models/` backup-exclusion | added | — |
| CI gates: Node matrix, iOS `swift test`, Android core + `assembleDebug`, catalog parity | green | `.github/workflows/ci.yml` |

Privacy policy is **written and hosted** (`website/privacy.html` → `https://quenderin.org/privacy`,
Cloudflare Pages) and **wired into the apps** — see section A.

---

## ⛔ The irreducible "needs you" list (literal 100% store-ready)

### A. Privacy policy — hosted + wired; only the console paste remains
- [x] Hosted as a static page: `https://quenderin.org/privacy` (Cloudflare Pages, from `website/privacy.html`).
- [x] Wired into the apps: `SupportContact.privacyPolicyURL` / `PRIVACY_POLICY_URL = https://quenderin.org/privacy`
      (both platforms), surfaced in the in-app **Settings** screen.
- [ ] **You:** paste the URL into App Store Connect **and** Play Console (a console field; needs the accounts in §D).

### B. In-binary contact detail
- [x] Dedicated support email for the "Report response" mailto, in-app Settings, and the website:
      `SupportContact.reportEmail` / `REPORT_EMAIL = quenderin@aulenor.com` — set on both platforms
      and across all website legal pages.

### C. Store-console questionnaires (no code — clicks in the consoles)
- [ ] **Age rating 17+ (App Store) / Mature 17+ (Play IARC)** — an unrestricted local LLM can emit
      mature text; file accordingly (filing lower is grounds for removal).
- [ ] **Apple Standard EULA** — App Information → opt in (one click; "Submit for Review" stays grey otherwise).
- [ ] **Play Data-Safety form** — answer "No data collected / No data shared" (accurate: only egress
      is the user-initiated HuggingFace model GET); declare the **`dataSync`** foreground-service type.
- [ ] **App Review notes (iOS 4.2)** — state the 0.4–9 GB download range, "be on Wi-Fi," and that
      onboarding *is* the first-use experience by design.

### D. Accounts, signing, assets (only you can)
- [ ] Apple Developer Program + Google Play Console accounts.
- [ ] Signing: iOS distribution cert/profile; Android upload/app-signing keystore. **Scaffolded** — the
      Android build reads a gitignored `keystore.properties` and signs `release` automatically; the full
      step-by-step (keystore generation + both stores' console steps) is in **`docs/RELEASE.md`**.
- [ ] Build the iOS xcframework + `xcodegen` the app target (`apple/QuenderinApp/INTEGRATION.md`);
      add `jni/llama.cpp` for the Android real-inference APK.
- [ ] Screenshots + store-listing copy. **Use app-specific copy** — describe the offline chat +
      pure-math agent; do **not** carry over the desktop README's "autonomous device control"
      language (the store apps don't have it).

### E. Physical-device ground truth (replaces conservative estimates)
- [ ] Run the smoke tests on a real iPhone and a real Android phone; capture tok/s + battery/thermals,
      then update `AppleChip.inferenceScore` / `AndroidSoc` + the tables in `apple/REALITY.md`.
      (The Mac/sim/emulator numbers are host-CPU ceilings, clearly labeled as estimates today.)

### F. Desktop (Electron prototype) — security audit `2026-06-23` (only you can finish)
The native apps above are the store targets; the Electron desktop is the working prototype. Its
HIGH-severity audit findings are **fixed in code** but two need *your* environment to finalize
(full ledger: `docs/audits/2026-06-23-code-review-security-audit.md`):
- [ ] **Live-verify the per-launch auth token (#1).** Launch the app (or `npm run dashboard`) and
      confirm the agent connects **and** model download/switch/delete still work — the renderer now
      sends the token; the server rejects un-tokened WS upgrades + mutating `/api` requests. (Pure
      logic is unit-tested + CI-green; only the live renderer round-trip can't be checked headlessly.)
- [ ] **Code-sign + notarize the desktop build (#9).** `asar` is on; signing needs your certs —
      macOS `CSC_LINK`/`CSC_KEY_PASSWORD` + `mac.notarize` (`APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/
      `APPLE_TEAM_ID`); Windows `CSC_LINK`. Steps are documented inline in `electron-builder.yaml`.
- [ ] *(Optional)* the privacy-lock passphrase is stored in `localStorage` (audit down-rates to
      MEDIUM for a single-user desktop app) — harden with a KDF if you ship the desktop build widely.

---

## How to read "100%"

- **Software readiness: 100%.** Code, compliance surface, tests, and CI are complete and green.
- **Both code-touching items are now closed:** the privacy-policy URL and the support email are real
  (`quenderin.org/privacy`, `quenderin@aulenor.com`) and wired into both apps.
- **Store readiness: gated only on Section A's console paste + Sections C–E** — store-console
  questionnaires, developer accounts, signing, store assets, and physical-device numbers. **None is
  a code change an agent can make** — they need your accounts, your hardware, and console clicks.
