# Microsoft Store — step-by-step (Windows desktop)

**Goal:** list **Quenderin** (Electron desktop, free) on the Microsoft Store for trust/branding
and SmartScreen-free installs, **while keeping** the same-version **GitHub Releases** `.exe`
(installer + portable) for direct download on [quenderin.org/download](https://quenderin.org/download.html).

| Channel | Artifact | Who signs | Auto-update |
|---|---|---|---|
| **Microsoft Store** | `.appx` / MSIX | **Microsoft** (store) | Store updates |
| **GitHub Releases** | `Quenderin-Setup-x64.exe`, portable | optional Authenticode; often unsigned in preview | You cut a new `v*` tag |

This guide is the **owner path** — Partner Center clicks and publisher identity only you can do.
Code already supports AppX via `electron-builder` (`npm run electron:build:win:store`).

Last updated: 2026-07-09 · app version **0.2.0**

---

## 0. What you need before day one

- [ ] A Microsoft account (personal is fine for individual publishers).
- [ ] **Microsoft Partner Center** enrollment — one-time fee for individual developers
      (historically ~US$19; confirm current fee at
      [partner.microsoft.com/dashboard](https://partner.microsoft.com/dashboard)).
- [ ] A Windows 10/11 machine (or a Windows CI agent) with **Node 20+**, **npm**, and
      **Windows SDK** components electron-builder needs for AppX (Visual Studio Build Tools
      “Desktop development with C++” + Windows 10/11 SDK is the usual fix if pack fails).
- [ ] Store assets ready (see §5): icon 44/50/150, screenshots, description, privacy URL.
- [ ] Repo built cleanly: `npm ci && npm run build` on that machine.

**Do not** put Partner Center secrets, PFX passwords, or publisher CNs into git.

---

## 1. Create the Partner Center account (once)

1. Open [https://partner.microsoft.com/dashboard](https://partner.microsoft.com/dashboard)
   and sign in with the Microsoft account that will **own** the listing.
2. Enroll as an **individual** (or company if you have a D-U-N-S / org registration).
3. Complete identity verification (ID / payment for the registration fee).
4. Wait until the dashboard shows **Apps and games** is available.

Checkpoint: you can open **Apps and games → Overview** without an enrollment banner.

---

## 2. Reserve the app name

1. Partner Center → **Apps and games** → **New product** → **MSIX or PWA app**.
2. Reserve the name **Quenderin** (or the closest available; keep it consistent with branding).
3. Note the **Store ID** / product page once created (you will need it for support links later).

Checkpoint: the product appears under Apps and games with status **Incomplete** / draft.

---

## 3. Copy product identity into `electron-builder.yaml`

Partner Center → your app → **Product management → Product identity** (wording may be
“App identity” / “Package identity”).

You need four values:

| Partner Center field | electron-builder key (`appx:`) | Example shape |
|---|---|---|
| Package/Identity name | `identityName` | `YourPublisher.Quenderin` |
| Publisher (CN=…) | `publisher` | `CN=A1B2C3D4-…` |
| Publisher display name | `publisherDisplayName` | `Your Name or Studio` |
| (application id segment) | `applicationId` | `Quenderin` (already set) |

Edit **`electron-builder.yaml`** under `appx:`:

```yaml
appx:
  applicationId: Quenderin
  displayName: Quenderin
  identityName: REPLACE.FROM.PARTNER.CENTER
  publisher: CN=REPLACE-GUID-FROM-PARTNER-CENTER
  publisherDisplayName: REPLACE Display Name
  languages:
    - en-US
  artifactName: "Quenderin-Store-${arch}.appx"
  backgroundColor: "#0B0F14"
```

**Critical:** `publisher` must match Partner Center **exactly** (including `CN=`). A mismatch
is the #1 reason Store packages fail validation on upload.

Optional but recommended: set `appId` at the top of the same file to a stable reverse-DNS
id (`com.quenderin.desktop` is already set) and do not change it between releases.

---

## 4. Build the Store package (AppX)

On **Windows**:

```bat
git checkout main
git pull
npm ci
npm run electron:build:win:store
```

Output (default):

```
release/Quenderin-Store-x64.appx
```

If electron-builder errors about `makeappx` / Windows SDK:

1. Install **Visual Studio 2022 Build Tools**.
2. Workload: **Desktop development with C++**.
3. Individual component: a current **Windows 10/11 SDK**.
4. Re-open the terminal and rebuild.

**Signing:** for Store upload you typically submit an **unsigned** or **test-signed** AppX;
Partner Center / the Store pipeline re-signs with the Microsoft distribution cert. Follow the
upload wizard’s current guidance if it asks for a `.msixupload` / package flight.

Also keep building the **GitHub** channel (CI does this on `v*` tags):

```bat
npm run electron:build:win
REM → release/Quenderin-Setup-x64.exe
REM → release/Quenderin-Portable-x64.exe
```

Do **not** replace GitHub artifacts with the AppX — ship **both**.

---

## 5. Store listing content (copy paste)

Use accurate, **desktop** language. The free Store build is local chat + model library +
governed tools that the desktop app actually ships. Do **not** claim iPhone control or
features only in unreleased Pro autonomy if they are not in the binary.

### Privacy

- Privacy policy URL: **https://quenderin.org/privacy** (already hosted).

### Age / content

- Unrestricted local LLM → file for **adult/mature** audiences where the questionnaire asks
  (same posture as App Store 17+ / Play Mature). Do not under-rate.

### Short description (example)

```
Private offline AI chat on your PC. Download open models, run them locally — nothing leaves your machine.
```

### Full description (example skeleton)

```
Quenderin is an offline AI assistant for Windows.

• Chat with open models (Llama, Qwen, Mistral, Gemma, …) on your own hardware
• Models download inside the app with integrity checks
• Nothing is sent to our servers for inference — private by design
• Free preview; large models need free disk space and a solid machine

By using Quenderin you agree that model output is not professional advice and may be wrong.
See https://quenderin.org/terms and https://quenderin.org/privacy.
```

### Screenshots / icons

Partner Center lists exact sizes. Minimum practical set:

- **Store logo / tiles:** 44×44, 50×50, 150×150 (and any required 300×300 / poster).
- **Screenshots:** at least 1 desktop screenshot (1366×768 or higher is typical); 3–4 is better
  (chat empty state, model library, a short reply, settings).
- Source brand assets live under `brand/` / `brand/electron/` (icons). Export clean PNG without
  “Electron” chrome if possible.

### Support contact

- Support email: **quenderin@aulenor.com** (same as mobile / site).
- Website: **https://quenderin.org**

---

## 6. Upload the package and submit

1. Partner Center → your Quenderin product → **Packages**.
2. Upload `Quenderin-Store-x64.appx` (or the `.msixupload` if you produce one).
3. Fix any **certification failures** (common: wrong publisher CN, missing logos, capability
   declarations, or large unpackaged native binaries — see electron-builder AppX docs).
4. Complete **Properties**, **Age ratings**, **Store listings**, **Privacy**, **Pricing**
   (**Free**).
5. **Submission → Submit to the Store**.

Review can take from hours to several days. Certification notes go to the Partner Center inbox.

---

## 7. After approval — dual channel discipline

| Action | Store | GitHub |
|---|---|---|
| Ship 0.2.0 | Upload AppX built from tag `v0.2.0` | Tag `v0.2.0` → `desktop-release.yml` publishes `.exe` |
| Bump version | Partner Center package version must increase | `package.json` version + git tag |
| Announce | Store listing auto-updates | website `download.html` always points at `releases/latest` |

**Version rule:** keep **marketing version aligned** (`package.json` → 0.2.0, Store package
version, and GitHub release title). Never ship Store 0.2.1 against GitHub still advertising 0.1.0
without updating the site.

---

## 8. Pricing & free listing

- Price: **Free**.
- No IAP required for v0.2 preview.
- If Pro / autonomy becomes paid later, that is a **product + package** change — do not
  promise paid features in the free Store description until the binary gates them.

---

## 9. Optional: CI for AppX later

Today AppX is **manual on Windows** so publisher identity stays local. Later you can add a
`workflow_dispatch` job that:

1. Runs on `windows-latest`.
2. Injects `publisher` / `identityName` from GitHub **Actions secrets** (never the public log).
3. Uploads `*.appx` as a release asset named `Quenderin-Store-x64.appx` **or** only as a
   private artifact for Partner Center upload.

Do not auto-publish to the Store from CI until Partner Center API automation is set up
deliberately.

---

## 10. Checklist (print this)

- [ ] Partner Center enrolled
- [ ] Name **Quenderin** reserved
- [ ] `electron-builder.yaml` `appx.identityName` / `publisher` / `publisherDisplayName` filled
- [ ] `npm run electron:build:win:store` → `release/Quenderin-Store-x64.appx`
- [ ] Screenshots + logos uploaded
- [ ] Privacy URL `https://quenderin.org/privacy`
- [ ] Age rating honest (mature LLM)
- [ ] Free price
- [ ] Package uploaded + submission sent
- [ ] GitHub `v0.2.0` (or current) still has Setup + Portable `.exe`
- [ ] download.html still links GitHub latest (Store badge can be added after live)

---

## Related docs

| Doc | Role |
|---|---|
| [WINDOWS_LINUX_STRATEGY.md](WINDOWS_LINUX_STRATEGY.md) | Why Electron on Win/Linux; channel ladder |
| [MAC_APP_STORE.md](MAC_APP_STORE.md) | **macOS** public path (native Swift, App Store only) |
| [RELEASE.md](RELEASE.md) | iOS / Android store + signing |
| [STORE_LISTING.md](STORE_LISTING.md) | Shared listing facts / accuracy guardrails |
| [SHIP_READINESS.md](SHIP_READINESS.md) | What’s software-complete vs owner-only |

---

## Troubleshooting (quick)

| Symptom | Likely cause |
|---|---|
| “Publisher identity mismatch” | `appx.publisher` ≠ Partner Center CN |
| `makeappx` / MakePri not found | Windows SDK / VS Build Tools missing |
| Package too large | Expected for apps bundling node-llama-cpp; ensure Store allows size or use on-demand model download (already the product model) |
| SmartScreen still on GitHub exe | Normal until Authenticode or users install from Store |
| Users ask “which Windows build?” | **Store** = auto-update + no SmartScreen; **GitHub** = portable / advanced / no Microsoft account |
