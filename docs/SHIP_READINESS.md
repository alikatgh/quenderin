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
| iOS brain + UI (M1–M4, picker, chat, agent, about/privacy) | done | `cd apple/QuenderinKit && swift test` → **143 tests** |
| Android brain (M1–M4, picker) + app module (Compose) | done | core: `kotlinc … CoreVerify.kt` → **all checks**; app: `cd android && ./gradlew :app:assembleDebug` |
| Real on-device inference (iOS xcframework / Android `jni/llama.cpp`) | proven both platforms | `apple/verify-llama-link.sh`, `android/verify-llama-link.sh` |
| Catalog parity across 3 platforms | enforced | `npm run check:catalog-parity` |
| **Gen-AI content safety** — disclaimer, Report affordance (chat+agent), agent answer/tool gate, **chat-output flag** (`ChatMessage.isFlagged`), agent **halt-reason** copy | done + parity-checked | covered by the suites above |
| iOS `PrivacyInfo.xcprivacy` (required-reason APIs) | added | in `apple/` |
| Android FGS `<service foregroundServiceType="dataSync">` (was an API-34 crash) | added | in `AndroidManifest.xml` |
| `ITSAppUsesNonExemptEncryption=false`, `models/` backup-exclusion | added | — |
| CI gates: Node matrix, iOS `swift test`, Android core + `assembleDebug`, catalog parity | green | `.github/workflows/ci.yml` |

Privacy-policy **text** is written (`docs/legal/privacy-policy.md`) — it just isn't *hosted* yet.

---

## ⛔ The irreducible "needs you" list (literal 100% store-ready)

### A. The one remaining hard **blocker** — host the privacy policy
- [ ] Host `docs/legal/privacy-policy.md` as a static page (GitHub Pages works).
- [ ] Put the URL in App Store Connect **and** Play Console.
- [ ] Tell me the URL and I'll replace the placeholder in code:
      `SupportContact.privacyPolicyURL` / `PRIVACY_POLICY_URL` (currently `https://example.com/quenderin-privacy`)
      and link it from the in-app About screen.

### B. In-binary contact detail (needs your value; I wire it)
- [ ] Dedicated support email for the "Report response" mailto. Current:
      `SupportContact.reportEmail` / `REPORT_EMAIL = wallmarketshq@gmail.com` (real, but flagged
      "change before publishing"). Give me the address and I'll set it on both platforms.

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
- [ ] Signing: iOS distribution cert/profile; Android upload/app-signing keystore.
- [ ] Build the iOS xcframework + `xcodegen` the app target (`apple/QuenderinApp/INTEGRATION.md`);
      add `jni/llama.cpp` for the Android real-inference APK.
- [ ] Screenshots + store-listing copy. **Use app-specific copy** — describe the offline chat +
      pure-math agent; do **not** carry over the desktop README's "autonomous device control"
      language (the store apps don't have it).

### E. Physical-device ground truth (replaces conservative estimates)
- [ ] Run the smoke tests on a real iPhone and a real Android phone; capture tok/s + battery/thermals,
      then update `AppleChip.inferenceScore` / `AndroidSoc` + the tables in `apple/REALITY.md`.
      (The Mac/sim/emulator numbers are host-CPU ceilings, clearly labeled as estimates today.)

---

## How to read "100%"

- **Software readiness: 100%.** Code, compliance surface, tests, and CI are complete and green.
- **Store readiness: gated on Section A–E above** — none of which is a code change (except B/A's
  placeholder swap, which I'll do the moment you provide the email + hosted URL).

When you give me **(1)** the hosted privacy-policy URL and **(2)** the support email, I can close the
only two code-touching items immediately; the rest are your console clicks and your developer accounts.
