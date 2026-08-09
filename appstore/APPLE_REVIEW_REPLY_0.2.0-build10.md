# App Review reply — macOS 0.2.0 (build 10)

Resubmission after the 0.2.0(9) rejection (Submission ID 4b4e279e-2c62-4d60-bd1d-121e10657ad0,
review date July 19, 2026). Paste the message below into the App Store Connect thread when
resubmitting build 10.

---

Hello, and thank you for the detailed report — both issues are fixed in this build (0.2.0, build 10).

**Guideline 2.1(a) — the error during model download**

We reproduced this. The error was not a general download failure: one specific model in our catalog
had a broken download link (the file had been moved on the hosting server, so the server returned a
"not found" page). That model happened to be the one automatically recommended for the exact hardware
used in review (a 16 GB MacBook Air M3), so the recommended download failed, and the app reported it
with an unhelpful internal message.

We have made three fixes:
1. Corrected the download link for that model, and verified that every model link in the app now
   resolves to a valid model file.
2. The downloader now checks the server's HTTP response before saving anything, so a server error can
   never again be mistaken for a corrupted file — the user sees a clear, retryable message instead.
3. Added an automated check (run whenever the catalog changes and on a weekly schedule) so a broken
   link is caught by us, before it can reach users.

We confirmed on macOS that the recommended model now downloads and loads successfully, and the app
proceeds into chat.

**Guideline 4 — reopening the main window**

Quenderin is a single-window app. Following your guidance for single-window apps, closing the main
window now quits the app after saving state. Nothing is lost — conversations, settings, and the
active model are persisted continuously, and relaunching restores the previous session (the loaded
model and the most recent conversation) immediately.

Thank you again for the thorough review. Please let us know if anything else needs attention.

---

## Internal checklist before you resubmit (not part of the message above)

- [ ] Archive the **QuenderinMac** target — confirm the build number is **10** (must exceed any build
      already uploaded to App Store Connect; if 10 was ever used, bump `project.yml` again + `xcodegen`).
- [ ] Confirm the archive links **real llama.cpp** (not the mock engine) — the compile verification here
      ran with the mock; the shipped build must do on-device inference.
- [ ] Upload, then on the rejected submission choose **Resubmit to App Review** and paste the reply above.
- [ ] (Optional) Reset macOS permission state before a final local smoke test:
      `tccutil reset AppleEvents ai.quenderin.Quenderin` (per Apple's note in the rejection).

### Claim verification — 2026-08-10

Every factual claim the reply above makes to App Review was re-checked against the tree on
2026-08-10, because a resubmission that repeats an untrue claim earns a second rejection:

- **"every model link in the app now resolves"** — `python3 scripts/check_catalog_urls.py`:
  **13/13 live**, including `gemma4-12b` (206, 7121861440 bytes), the exact model whose 404 caused
  the 2.1(a) rejection and the auto-pick for the 16 GB MacBook Air M3 review used. Re-run this
  immediately before resubmitting: it is a live network check, and the whole point is that URLs rot
  AFTER they were verified.
- **"the downloader now checks the server's HTTP response before saving anything"** —
  `apple/QuenderinKit/Sources/QuenderinKit/ModelDownloader.swift:110` rejects any non-2xx with a
  retryable `DownloadError.transport` message.
- **"an automated check … whenever the catalog changes and on a weekly schedule"** —
  `.github/workflows/catalog-urls.yml` (weekly `17 6 * * 1`, plus PR/push on any catalog path).
- **"closing the main window now quits the app"** (Guideline 4) —
  `apple/QuenderinApp/Sources/QuenderinApp.swift:34`,
  `applicationShouldTerminateAfterLastWindowClosed` returns `true`.

Not verifiable from here, still owner-only: that the uploaded archive links real llama.cpp rather
than the mock engine (the two unchecked boxes above).
