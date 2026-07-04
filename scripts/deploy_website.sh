#!/bin/bash
# Deploy the marketing site to ALL live targets in one motion:
#   1. GitHub Pages  (alikatgh.github.io/quenderin) — via the repo workflow
#   2. quenderin.org — the WORKER named "quenderin" (Workers custom domain), via
#      `wrangler deploy --config wrangler.site.jsonc`. THIS is what actually serves
#      the apex — discovered 2026-07-04 after Pages deploys silently went nowhere.
#   3. Cloudflare Pages project "quenderin" (quenderin.pages.dev) — preview mirror.
#
# Requirements: `gh` authenticated; `wrangler login` done once on this machine
# (Cloudflare account: wallmarketshq — the quenderin.org zone lives there).
# Pushes to main also auto-deploy GitHub Pages; Cloudflare needs this script
# until the CLOUDFLARE_API_TOKEN repo secret exists (then CI does it too).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ GitHub Pages (workflow)…"
gh workflow run deploy-website.yml

echo "→ quenderin.org (the Worker — the real apex)…"
npx --yes wrangler deploy --config wrangler.site.jsonc

echo "→ Cloudflare Pages preview (quenderin.pages.dev)…"
npx --yes wrangler pages deploy website --project-name quenderin --branch main --commit-dirty=true

echo "✓ all targets deploying — verify: https://quenderin.org + https://alikatgh.github.io/quenderin/"
