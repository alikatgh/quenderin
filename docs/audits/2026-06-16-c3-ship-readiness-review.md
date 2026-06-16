# C3 Ship-Readiness Review — `feat/ship-readiness`

**Date:** 2026-06-16
**Scope:** Audit finding **C3 — model-download integrity verification** (plus mobile CI) across desktop (Electron/TS), iOS (Swift), Android (Kotlin), the hand-synced catalog, and the parity/sync tooling.
**Reviewers:** 6-dimension fan-out (ts-desktop, swift-ios, kotlin-android, catalog-data, ci-yaml, consistency) with dual-lens adversarial verification.

---

## Ship verdict

**🚫 BLOCKING — do not merge as-is.** C3 is **defeated on two of the three platforms**: the desktop early-return path skips integrity verification entirely for any pre-existing model file, and the iOS background-download path always passes `sha256 == nil`, silently downgrading to magic-header-only verification for every production download. Both are confirmed critical security bypasses of the exact threat C3 was built to stop. They must be fixed before merge.

After the two criticals are fixed, the remaining findings (1 high, 3 medium, 2 low) are not individually merge-blocking but should be addressed in the same PR since several are latent traps that activate on the next catalog change.

---

## Confirmed findings by severity

Counts: **2 critical · 1 high · 3 medium · 2 low**

### CRITICAL

#### C3-1 · Desktop: pre-existing model file bypasses ALL integrity checks
- **File:** `src/services/llm.service.ts:667-675`
- **What:** The "already downloaded" early-return checks only `fs.existsSync(dest)` and `stats.size > 100_000_000`, then emits `progress: 100` and `return`s. `verifyModelIntegrity` (which lives at line 818) is **never called** on a pre-existing file.
- **Why it matters:** A file planted at the model path before first launch (supply-chain / another app writing there), a previously-clean file later corrupted in place (bit-rot, partial overwrite), or an attacker-substituted file is handed straight to node-llama-cpp's GGUF parser with **no magic-header and no SHA-256 gate**. The threat model names exactly these — silently-truncated transfers and substitution triggering llama.cpp memory-corruption → RCE CVEs. This path is checked on **every app launch**, so a corrupt-on-disk file is re-accepted indefinitely. (Reported independently by both the ts-desktop and consistency dimensions — same root cause.)
- **Fix:** Verify before trusting the cached file. Inside the size check, call `await verifyModelIntegrity(dest, entry.sha256)`; on success emit 100% and return; on failure delete `dest` (and `metaPath`) and fall through to a fresh download:
  ```ts
  if (fs.existsSync(dest)) {
    const stats = await fs.promises.stat(dest);
    if (stats.size > 100_000_000) {
      try {
        await verifyModelIntegrity(dest, entry.sha256);
        this.emit('model_download_progress', { progress: 100, modelId: entry.id });
        this.isDownloading = false;
        if (fs.existsSync(metaPath)) fs.unlinkSync(metaPath);
        return;
      } catch {
        try { fs.unlinkSync(dest); } catch { /* ignore */ }
        try { fs.unlinkSync(metaPath); } catch { /* ignore */ }
        // fall through to re-download
      }
    }
  }
  ```

#### C3-2 · iOS: background-download path silently skips SHA-256 (modelId is the filename, not the catalog id)
- **File:** `apple/QuenderinKit/Sources/QuenderinKit/BackgroundModelDownloader.swift:40-41` (consumed at lines 124–135)
- **What:** The `ModelDownloader` protocol conformance calls `download(from:to:modelId: destination.lastPathComponent)`. For `.../models/qwen3-14b.Q4_K_M.gguf`, `lastPathComponent` is `"qwen3-14b.Q4_K_M.gguf"` — the **filename**, not the catalog id (`"qwen3-14b"`). In `didFinishDownloadingTo`, `ModelCatalog.entry(id: resolved)` searches by `id` and therefore **always returns `nil`**, so `expectedSHA256` is always `nil` and `ModelIntegrity.verify` falls back to magic-header-only.
- **Why it matters:** This is the path `OnboardingModel` wiring hits (the protocol only exposes the two-arg form). The full SHA-256 gate is **silently bypassed for every production download** on iOS's background path, even though all catalog entries pin a real SHA-256. The foreground `URLSessionModelDownloader.download(from:to:)` does it correctly via `ModelCatalog.models.first { $0.downloadURL == url }` — so the two paths diverge, and the wrong one ships.
- **Fix:** Resolve the catalog id from the **download URL**, matching the foreground downloader; only fall back to the filename for genuinely off-catalog downloads:
  ```swift
  let modelId = ModelCatalog.models.first { $0.downloadURL == url }?.id
                ?? destination.lastPathComponent
  download(from: url, to: destination, modelId: modelId)
  ```
  Add a `BackgroundModelDownloaderTests` case driving a catalog-registered URL through the protocol path and asserting the SHA-256 gate runs.

### HIGH

#### C3-3 · Android: `ModelIntegrity.sha256Hex(ByteArray)` is in-memory — OOM trap, diverges from TS/iOS streaming twins
- **File:** `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelIntegrity.kt:26-27`
- **What:** The only SHA-256 entry point on the public `ModelIntegrity` object takes a whole `ByteArray`. Its twins — desktop `sha256File` (modelIntegrity.ts) and iOS `sha256Hex(of: URL)` (ModelIntegrity.swift) — both **stream in constant memory**.
- **Why it matters:** Production avoids the OOM today only because `ModelDownloadEngine.kt:123` hashes via the `sink.sha256(tempPath)` seam (64 KB chunks). But the public canonical utility, advertised as the cross-platform twin, will OOM the JVM heap on any 2–8 GB GGUF the moment a future caller (load-time re-verification, a "verify model" UI action, a test helper) reaches for it. The name gives no hint it's in-memory only. A real divergence and API safety trap — not merge-blocking, but worth fixing while the surface is fresh.
- **Fix:** Add `fun sha256Hex(file: java.io.File): String` that streams (mirroring `JvmFileSink.sha256`), make it the canonical implementation `ModelDownloadEngine` calls, and mark/deprecate the `ByteArray` overload `internal` (kept for small-buffer unit tests).

### MEDIUM

#### C3-4 · Android: cross-filesystem `finalize()` fallback can leave a corrupt final file
- **File:** `android/quenderin-core/src/main/kotlin/ai/quenderin/core/JvmDownloadIO.kt:115-125` (engine catch at `ModelDownloadEngine.kt:139-143`)
- **What:** `finalize()` deletes `dest` (line 119), tries atomic `renameTo` (line 120), and on cross-filesystem failure (internal storage → SD card) falls back to `copyTo(dest, overwrite=true)` then `temp.delete()` (lines 122-123). If `copyTo` throws mid-write (disk full / I/O error), the exception propagates to the engine's outer catch, which sets `FAILED` and rethrows but does **not** delete `finalPath`.
- **Why it matters:** `finalPath` is left partially-written and corrupt (the intact `tempPath` still exists, but the integrity gate already passed and won't re-run). Any app-layer "is the model installed?" check that tests `File(finalPath).exists()` finds a corrupt file and hands it to llama.cpp without re-verifying — re-opening the C3 hole on the SD-card path. The same-filesystem `renameTo` path is atomic and unaffected.
- **Fix:** In `finalize()`, wrap the fallback so a partial copy is cleaned up before rethrow: `try { temp.copyTo(dest, overwrite = true); temp.delete() } catch (e: Exception) { runCatching { dest.delete() }; throw e }`. Also have the engine catch block call `sink.truncate(finalPath)` alongside marking `FAILED`.

#### C3-5 · `export_catalog.py` treats `sha256` as required, but the type system declares it optional
- **File:** `scripts/export_catalog.py:69`
- **What:** The `s("sha256")` helper (lines 47-51) calls `sys.exit()` with a FATAL message when the field is absent. But `sha256` is `String?` in Swift (`ModelCatalog.swift:46`) and `String? = null` in Kotlin (`ModelCatalog.kt:43`), and the threat model explicitly allows magic-only verification when sha256 is null.
- **Why it matters:** This is a **workflow-state landmine**, not hypothetical: the script's own docstring documents adding a model to `constants.ts` *before* running `refresh_model_hashes.py`. In that documented intermediate state, `export_catalog.py` crashes FATAL and blocks the entire manifest-regeneration pipeline instead of emitting `null`. Latent today only because all 11 entries carry a hash.
- **Fix:** Add an optional `s_opt()` variant returning `None` when the key is absent, and use it for sha256: `"sha256": s_opt("sha256")`.

#### C3-6 · `check_catalog_parity.py` regex crosses model-entry boundaries when `sha256` is absent
- **File:** `scripts/check_catalog_parity.py:57-63` (regex at line 58)
- **What:** `parse_named` uses one `re.DOTALL` span with `.*?` between fields, ending at the sha256 literal. With DOTALL, a sha256-less entry causes the non-greedy `.*?` to spill past the entry boundary and grab the **next** model's hash — pairing the wrong id with the wrong hash. An entry lacking sha256 at the end of the list is silently dropped (count mismatch → "missing" error with the wrong diagnosis). Compounding: `load_canonical()` (line 98) uses `m.get("sha256", "")`, so the manifest carries `""` while `parse_named` borrows a neighbor's 64-char hash — a guaranteed false mismatch or false pass.
- **Why it matters:** Same trigger as C3-5 — the documented "new model before refresh" state. The parity guard that's supposed to catch cross-platform drift would itself misreport, undermining trust in the one tool meant to keep TS/Swift/Kotlin/JSON in sync. Latent today (all 11 entries have hashes).
- **Fix:** Split the catalog text into per-entry blocks first (split on `ModelEntry` / object-literal boundaries), then extract each field per-block without DOTALL, using an optional capture group for sha256 (absence → `None`, never borrowed).

### LOW

#### C3-7 · iOS: `URLSessionModelDownloader` leaks a `FileHandle` on download error
- **File:** `apple/QuenderinKit/Sources/QuenderinKit/ModelDownloader.swift:51` (closed only on happy path at line 74)
- **What:** The `FileHandle(forWritingTo: partial)` opened at line 51 is closed explicitly at line 74 on the happy path only. If `for try await byte in bytes` (line 58) throws — network error or Task cancellation routing to the catch at lines 95-98 — the handle is never closed. No `defer`.
- **Why it matters:** Each failed download leaks a file descriptor. Repeated failures (network flaps / onboarding retries) accumulate until the per-process fd limit, after which all file opens fail with `EMFILE`. Correctness/resource defect, not a C3 bypass.
- **Fix:** `let handle = try FileHandle(forWritingTo: partial); defer { try? handle.close() }` — closes on success, throw, and cancellation.

#### C3-8 · Android: `DownloadStore` retains a stale `FAILED` entry after integrity failure
- **File:** `android/quenderin-core/src/main/kotlin/ai/quenderin/core/ModelDownloadEngine.kt:117-142`
- **What:** On magic/SHA-256 failure the engine calls `sink.truncate(tempPath)` and throws; the catch (lines 139-141) sets `setState(FAILED)` but does **not** call `store.remove(model.id)` (that only happens on the success path, line 137). The FAILED record — with `bytesDownloaded` reflecting the now-truncated partial — persists until the next `download()` overwrites it via `upsert(...RUNNING...)`.
- **Why it matters:** The download itself isn't blocked, but any UI observer or WorkManager retry logic reading store state in the failure→retry window sees inconsistent resume accounting. Platform-specific asymmetry: iOS and desktop have no persistent store and leave no residual state. Low severity.
- **Fix:** Add `store.remove(model.id)` before the rethrow (or document that the next `download()` atomically overwrites it).

#### Also confirmed (low, folded into C3-8's tier) — test-seam divergence `FakeFileSink.sha256` vs `JvmFileSink.sha256`
- **File:** `android/quenderin-core/src/verify/CoreVerify.kt:36`
- `FakeFileSink.sha256` returns the hash of empty bytes (`e3b0c442…`) for a missing path, while production `JvmFileSink.sha256` throws `FileNotFoundException`. No current test exercises it, so nothing is broken — but it would mask a future regression where `sha256` is called before the file is fully written: the fake silently returns the wrong hash and the test passes while production throws. Fix: have the fake throw `FileNotFoundException` when the path is absent. (Recorded as a distinct confirmed low; see raw JSON.)

---

## Dimensions reviewed / what was checked

Six dimensions, each scoped to its own files (no wide-repo grep), with a fresh adversarial verifier per subsystem applying both "is this real?" and "is this a false positive?" lenses.

| Dimension | Surface checked | Outcome |
|-----------|-----------------|---------|
| **ts-desktop** | `src/services/llm.service.ts`, `src/.../modelIntegrity.ts`, `tests/modelIntegrity.test.ts` | 1 critical (C3-1). Empty-file "no test" finding **rejected** as a coverage observation, not a bug (`hasGGUFMagic` already guards `length < 4`). |
| **swift-ios** | `BackgroundModelDownloader.swift`, `ModelDownloader.swift`, `ModelIntegrity.swift` | 1 critical (C3-2). Background path verified as the OnboardingModel wiring; foreground path confirmed correct. |
| **kotlin-android** | `ModelIntegrity.kt`, `JvmDownloadIO.kt`, `ModelDownloadEngine.kt`, `verify/CoreVerify.kt` | 1 medium (C3-4) + 1 low (seam) confirmed; the OOM API-trap was re-surfaced and confirmed HIGH by the consistency dimension (C3-3). The kotlin-android dimension's own copy of the OOM finding was rated low/`isReal=false` (speculative there), so the HIGH framing from the cross-platform-equivalence lens governs. |
| **catalog-data** | `scripts/export_catalog.py`, `scripts/check_catalog_parity.py`, `ModelCatalog.swift/.kt`, manifest JSON | 2 mediums (C3-5, C3-6) — both latent regex/optional-field bugs that fire on the documented "new model before hash refresh" workflow state. |
| **ci-yaml** | mobile CI workflow(s) | **No findings.** Workflow scoped clean. |
| **consistency** | All three platforms' integrity twins + the desktop early-return regression | Re-confirmed C3-1 (cross-platform divergence framing), C3-3 (high), C3-7, C3-8. |

**Hash spot-check vs HuggingFace:** the per-model SHA-256 values pinned in the catalog were spot-checked against HuggingFace LFS pointers where the sandbox network allowed. The catalog/manifest values are internally consistent across TS/Swift/Kotlin/JSON for all 11 current entries (the parity guard passes today because every entry carries a hash); the latent tooling bugs C3-5/C3-6 do not affect today's data — only the next add-a-model step.

---

## Residual risk

1. **Catalog tooling is one step from broken.** C3-5 and C3-6 are both invisible today and both detonate on the *same* routine action — adding a model to `constants.ts` before running `refresh_model_hashes.py`. Until both are fixed, that documented workflow is a trap: the export crashes and the parity guard misreports. Highest residual risk after the criticals.
2. **The OOM trap (C3-3) is a loaded gun behind a safe muzzle.** Production routes around it via the FileSink seam, but the public API still invites a multi-GB in-memory hash. The first load-time re-verification feature or test helper that uses the obvious public method will crash on real models.
3. **Cross-filesystem path on Android (C3-4)** is exercised only by users moving models to SD storage; it won't appear in CI or on most devices, so it can ship unnoticed and silently re-open the integrity hole for that minority.
4. **fd-leak (C3-7) and stale-FAILED (C3-8)** are reliability/UX papercuts that degrade only under repeated failures; no integrity impact.
5. **Verification confidence:** all confirmed findings are `confidence: medium` — each grounded in cited code re-read by the verifier, but none dynamically reproduced (no model was downloaded end-to-end in this review). The two criticals are unambiguous from the control flow; the latent catalog bugs were demonstrated with synthetic inputs by the finder.

**Bottom line:** fix C3-1 and C3-2 (criticals) to restore the C3 control on desktop and iOS; fold C3-3 through C3-8 into the same PR since they touch the same files and several are next-change landmines. Then re-run the test suites and `check_catalog_parity.py` — at that point this branch is mergeable.
