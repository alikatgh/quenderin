# Launch checklist — the only things that need *you*

Everything verifiable in software is done and green (see `STATUS.md`). The items below are
the ones an AI agent genuinely can't do — they need your hardware, your accounts, or your
private legal details. Each is reduced to the smallest possible action.

## 1. Watch the engine run (5 min, no risk) ✅ proven, just reproduce
```bash
apple/verify-llama-link.sh        # builds real llama.cpp, runs inference on Mac Metal + iPhone sim
android/verify-llama-link.sh      # the Android twin (needs a complete NDK — see §3)
```
You'll see coherent output ("the sky is blue because…") at ~177 tok/s (Mac) / ~160 (sim).

## 2. Ship iOS on a real device
- [ ] Build the xcframework: `git clone … llama.cpp && cd llama.cpp && ./build-xcframework.sh`
      (or follow **Route A** in `apple/QuenderinKit/INTEGRATION.md`). A concurrent change is
      also wiring a `QUENDERIN_LLAMA_DIR` source-build path — check `Package.swift`/`Sources/llama/`.
- [ ] Flip the two lines in `apple/QuenderinApp/Sources/QuenderinApp.swift`:
      `MockInferenceEngine()` → `LlamaEngine()`, `MockModelDownloader()` → `URLSessionModelDownloader()`.
- [ ] `brew install xcodegen && (cd apple/QuenderinApp && xcodegen)` → open + run on a device.

## 3. Ship Android on a device/emulator
- [ ] The NDK at `ndk/27.1.12297006` is a 4 KB **stub**; `27.0.12077973` is complete (the
      verify script auto-picks a complete one). If neither works: `sdkmanager "ndk;27.0.12077973"`.
- [ ] `android/verify-llama-link.sh` (needs ~3 GB free disk + a booted emulator/device).
- [ ] Uncomment the `externalNativeBuild` + `ndk { abiFilters }` blocks in `android/app/build.gradle.kts`
      and add llama.cpp under `android/jni/` (a git submodule). Then build in Android Studio.

## 4. Fill the legal placeholders (your entity details — I can't invent these)
| File:line | Placeholder |
|-----------|-------------|
| `website/privacy.html:35` | `[LEGAL NAME / ENTITY]` |
| `website/privacy.html:36` | `[POSTAL ADDRESS]` |
| `website/privacy.html:59` | `[FORM PROVIDER …]` (or remove if no form — see §5) |
| `website/terms.html:39`   | `[trademarks / property of OPERATOR]` |
| `website/terms.html:48`   | `[JURISDICTION]` |
| `website/legal.html:32`   | `[LEGAL NAME OR COMPANY]` |
| `website/legal.html:34`   | `[STREET, POSTAL CODE, CITY, COUNTRY]` |
| `website/legal.html:40`   | `[PHONE, if required]` |
| `website/legal.html:50`   | `[NAME & ADDRESS of the person responsible]` |

## 5. Waitlist form (or remove it)
- [ ] `website/index.html:339` — replace `action="https://formspree.io/f/your-form-id"` with a
      real endpoint, **or** delete the `<form>` (the form already degrades honestly until then).

## 6. Website deploy (GitHub Pages)
- [ ] The deploy workflow needs to live at `.github/workflows/` — pushing it requires a token
      with the **`workflow`** scope (the env token here lacks it). Then Settings → Pages → Source: "GitHub Actions".

## 7. App Store / Play submission
- [ ] Apple Developer + Google Play accounts, signing, screenshots, store listings.

## 8. Replace estimated chip scores with measured (after §2/§3 on real hardware)
- [ ] Capture real **on-phone** tok/s + battery (run the smoke tests on a physical device), then
      update `AppleChip.inferenceScore` / `AndroidSoc` and the tables in `apple/REALITY.md`. The
      current scores are conservative, clearly-labeled estimates; the Mac/sim numbers are ceilings.
