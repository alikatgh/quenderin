# Quenderin project memory

Read [docs/RELEASE.md](docs/RELEASE.md) before preparing native updates. It records
the existing Apple Xcode Cloud workflow, Google Play app/track, registered upload
certificate, signing configuration, and dated verification status. Refresh live
build counters and console state; do not restart account setup or invent keys.

Model integration details are in [docs/bonsai-2.md](docs/bonsai-2.md). Runtime
provenance lives in `shared/prism-runtime.json`; Muse's complete artifact manifest
lives in `shared/muse-spark-artifacts.json`. Run the existing catalog/provenance
checks before publishing. Never label a source-only integration as tested inference.

For the October 2026 update the user explicitly requires no local model-weight
downloads and no simulator or physical-device runs. Use host fixtures and hosted
compilation; report the remaining inference/UI verification gap separately.

The public website is the Cloudflare Worker `quenderin` at `quenderin.org`.
GitHub Pages and `quenderin.pages.dev` are separate mirrors. Preserve the current
plain homepage and `tell-me-more.html` when updating generated catalog content.

Secrets and private keys never belong in this file or release documentation.

## Store browser profiles — verified 19 October 2026

- **App Store Connect / Xcode Cloud:** Chrome profile **Apple Developer**.
- **Google Play Console:** Chrome profile **Albert - Main - CMax**.
- **Cloudflare publishing:** Chrome profile **Albert - Main - CMax**, approved by the user on 19 October 2026.
- Confirm the profile name and reuse its signed-in tab before any store work.
  Browser and tab IDs are ephemeral, not account identifiers. Do not open Play
  Console in Apple Developer or App Store Connect in the general browsing profile.
- See `docs/RELEASE.md` for exact app/track identifiers and signing prerequisites.
  Store access and possession of the Android upload key are separate facts.
