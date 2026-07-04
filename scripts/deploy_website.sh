#!/bin/bash
# Deploy the marketing site to BOTH live targets in one motion:
#   1. GitHub Pages  (alikatgh.github.io/quenderin) — via the repo workflow
#   2. Cloudflare Pages project "quenderin" (quenderin.org) — via wrangler
#
# Requirements: `gh` authenticated; `wrangler login` done once on this machine
# (Cloudflare account: wallmarketshq — the quenderin.org zone lives there).
# Pushes to main also auto-deploy GitHub Pages; Cloudflare needs this script
# (the CF project is direct-upload, not git-connected).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ GitHub Pages (workflow)…"
gh workflow run deploy-website.yml

echo "→ Cloudflare Pages (quenderin.org)…"
npx --yes wrangler pages deploy website --project-name quenderin --branch main --commit-dirty=true

echo "✓ both targets deploying — verify: https://quenderin.org + https://alikatgh.github.io/quenderin/"
