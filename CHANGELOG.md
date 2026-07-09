# Changelog

## 0.2.0 — 2026-07-09

### Distribution
- **Version alignment:** desktop (`package.json`), Android (`0.2.0` / versionCode 2), Apple
  marketing version `0.2.0` / build 2.
- **Windows dual channel:** GitHub Releases keep Setup + Portable `.exe`; Microsoft Store path
  via AppX (`npm run electron:build:win:store`) — full owner guide
  [`docs/MICROSOFT_STORE.md`](docs/MICROSOFT_STORE.md).
- **macOS public product:** native **QuenderinMac** App Store only (free listing for branding) —
  [`docs/MAC_APP_STORE.md`](docs/MAC_APP_STORE.md). Electron mac remains lab-only; CI desktop
  release stays Windows + Linux only.
- Website `download.html` updated for Store policy + v0.2.x.

### Product-path engineering (desktop / core)
- Sampling profiles: shared JSON + CI parity; packaged Electron loads `shared/` with embedded
  fallback.
- Android PDF text extract (pure-Kotlin) + FlateDecode; desktop sampling + golden chores in CI.
- GUI reliability: `verify()` on type/key/menu (TS + Swift).
- Skill memory: record/recall **tool + input** sequences (`recordSteps` / `formatHint`).
- Chore breadth: `fs.organize` (batch by type, durable undo), `fs.collect` (multi-file read for
  summarize → `fs.write` reports).

### Notes for owners cutting the release
1. Tag `v0.2.0` → GitHub Actions publishes Win/Linux installers.
2. On Windows: fill Partner Center identity in `electron-builder.yaml` `appx.*`, then
   `npm run electron:build:win:store` and follow MICROSOFT_STORE.md.
3. On Mac: `docs/MAC_APP_STORE.md` for App Store Connect upload of QuenderinMac 0.2.0 (2).

## 0.1.0 — earlier

First public desktop preview (Windows/Linux installers), native mobile software-complete baseline.
