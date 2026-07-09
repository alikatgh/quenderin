# Windows + Linux strategy — full-platform coverage without a rewrite

**Status:** adopted 2026-07-04. Owner directive: cover macOS + Windows + Linux ASAP,
easiest possible installation (Microsoft Store as free software), direct installation
files on the website for everything except macOS.

## The one-sentence strategy

Ship the **existing Electron desktop app** (already cross-platform, already
security-audited, already packaging-configured) as the Windows/Linux client **today**,
distribute through **GitHub Releases → website direct links now, stores next**, and
treat a native/Compose rewrite as a *later* optimization to make only if Electron's
footprint measurably hurts adoption.

## Why Electron is the right v1 (and not a compromise we should feel bad about)

- **It already exists.** `src/electron/` + the React dashboard are a working app:
  window-security hardening (navigation pinning, contextIsolation, asar), tray, port
  discovery, dark chrome. It went through the 2026-06-27 adversarial deep-hunt.
- **Inference is solved.** `node-llama-cpp` ships prebuilt llama.cpp binaries for
  win-x64 and linux-x64 — the same engine family as every other Quenderin platform, so
  the model catalog, SHA-256 pinning, and RAM-fit logic transfer unchanged
  (`src/constants.ts` IS the canonical catalog source).
- **One codebase, three desktop OSes.** LM Studio, Ollama's UI, Jan — the entire
  local-LLM desktop category ships Electron or similar. Users accept it; disk-heavy
  GGUF files dwarf the runtime anyway.
- **The alternative burns the lead.** A Compose Multiplatform port (attractive because
  `android/quenderin-core` is pure JVM and parity-enforced) is the *strategic* second
  step, not the first: it needs a new JNI llama.cpp build per OS/arch, a desktop UI
  port, and months. Do it if/when Electron's ~250 MB install proves to be a real
  objection — measure first.

## Distribution ladder (easiest-trust first)

| Channel | Status | Trust/friction | Action |
|---|---|---|---|
| **GitHub Releases** | ✅ live via `desktop-release.yml` | Devs trust it; SmartScreen may warn | Free public-repo runners build win+linux on every `v*` tag — **keep forever** alongside Store |
| **Website direct links** | ✅ `website/download.html` | Same files, friendlier storefront | `releases/latest/download/<stable-name>` — links never go stale |
| **Microsoft Store** | 🔧 ready to submit | **Best Windows trust**: store-signed, no SmartScreen, auto-updates | Free listing. Owner playbook: **[MICROSOFT_STORE.md](MICROSOFT_STORE.md)**. Build: `npm run electron:build:win:store` → AppX |
| **winget** | cheap follow-up | `winget install quenderin` | One PR to microsoft/winget-pkgs pointing at the GitHub release |
| **Flathub** | next for Linux | The de-facto Linux app store; free | Submit a flatpak manifest wrapping the release; AppImage/deb remain for direct users |
| **Snap** | optional | Ubuntu default store | Only if users ask; Flathub covers most distros |

**macOS is not on this ladder.** Public Mac = **native App Store only** ([MAC_APP_STORE.md](MAC_APP_STORE.md)). Electron mac is lab-only.

**Code signing:** unsigned GitHub `.exe` may trip SmartScreen. Tiers: live with the warning
(v0.2 preview) → **Microsoft Store** (Microsoft signs — keep GitHub exe anyway) → optional
Azure Trusted Signing for the direct `.exe` when volume justifies it. Linux needs no signing.

## What ships free vs. what we hold back

The desktop testbed contains the **autonomous device-driver agent** — per the
monetization direction (2026-07-04), autonomy is the paid tier and must not become
the free default. The Windows/Linux **v0.2.x releases are labeled "preview"**; before
a 1.0 marketing push, split the build: chat + model library + task router free,
autonomous computer use behind a Pro flag. (Tracked as a release-blocking product
decision, not a nice-to-have.)

## Platform-parity discipline extends, not bends

Desktop TS is already the canonical catalog source; the router/agent/degeneration
logic has parity vectors. Any new desktop-side logic that has a Swift/Kotlin twin
gets vectors + a `check_*_parity.py` entry — no exceptions just because "it's only
Electron."

## The agent (the mission) on Windows/Linux — started 2026-07-07

Chat always worked on win/linux (node-llama-cpp prebuilds); the AGENT was macOS-only because
the capability library was. First port slice shipped: `platformAutomation.ts` (an argv-only
`CommandRunner` — fixed commands; user values ride as their own argv elements or as environment
variables read by fixed PowerShell scripts, so there is NO interpolation layer to escape) and
`platformCapabilities.ts`: **win.\*** (clipboard.read, explorer.reveal · app.open via the
`$env:` value channel, url.open via rundll32) and **linux.\*** (clipboard.read with
wl-paste→xclip fallback, files.reveal · url.open via xdg-open, notify.send). Wired into
`quenderin do` (the macOS-only guard is gone), `quenderin capabilities`, and the dashboard's
governed Tasks service — same spine, per-run approval, ledger. Next capabilities to grow:
front-window perception, a notifications twin on Windows, and app-launch on Linux
(gtk-launch/.desktop resolution — needs care across distros).

1. **Done (2026-07-04 → 0.2.0):** CI builds Quenderin-Setup-x64.exe, Quenderin-Portable-x64.exe,
   AppImage, `.deb` on free runners; website download page; macOS excluded from Electron
   releases (native App Store). AppX packaging + Partner Center guide shipped
   ([MICROSOFT_STORE.md](MICROSOFT_STORE.md)); `npm run electron:build:win:store`.
2. **Owner next:** complete Microsoft Store submission (identity in `electron-builder.yaml`
   `appx.*`), winget manifest, Flathub. Optional electron-updater for direct
   installs.
3. **Before 1.0:** free/Pro split of the agent; Windows arm64 + Linux arm64 builds
   (node-llama-cpp prebuilds exist); signing decision by download volume.
4. **Re-evaluate (data, not vibes):** if install-size complaints or memory footprint
   show up in real feedback, prototype Compose Desktop on `quenderin-core`; the parity
   harness makes the port verifiable.
