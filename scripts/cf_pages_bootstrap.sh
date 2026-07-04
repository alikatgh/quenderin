#!/bin/bash
# Onboard ANY GitHub repo (private or public) onto auto-deploying Cloudflare Pages —
# push to the repo, the CF marketing site updates. $0/month hosting, zero manual deploys.
#
#   Usage:  CF_PAGES_TOKEN=<token> scripts/cf_pages_bootstrap.sh <owner/repo> <cf-project> <publish-dir> [branch]
#   e.g.:   CF_PAGES_TOKEN=xxx scripts/cf_pages_bootstrap.sh alikatgh/quenderin quenderin website main
#
# One-time prerequisite (once for ALL repos): mint an API token at
# dash.cloudflare.com → My Profile → API Tokens → Create Token → custom:
#   Account · Cloudflare Pages · Edit        (deploys)
#   Zone    · DNS             · Edit         (optional: lets custom domains attach cleanly)
# Then export it as CF_PAGES_TOKEN when running this script.
#
# What it does per repo:
#   1. Creates the Cloudflare Pages project if missing (direct-upload type).
#   2. Sets the repo's CLOUDFLARE_API_TOKEN secret (via gh).
#   3. Commits a .github/workflows/deploy-cf-pages.yml into the repo that deploys
#      <publish-dir> on every push to <branch> touching it.
set -euo pipefail

REPO="${1:?owner/repo}"; PROJECT="${2:?cf project name}"; DIR="${3:?publish dir}"; BRANCH="${4:-main}"
ACCOUNT_ID="4c1e57b6972105286a7aeb46b2b89c78"   # wallmarketshq
: "${CF_PAGES_TOKEN:?export CF_PAGES_TOKEN=<api token> first (see header)}"

echo "→ ensuring Cloudflare Pages project '$PROJECT' exists…"
CLOUDFLARE_API_TOKEN="$CF_PAGES_TOKEN" CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID" \
  npx --yes wrangler pages project create "$PROJECT" --production-branch "$BRANCH" 2>/dev/null \
  || echo "  (already exists)"

echo "→ setting CLOUDFLARE_API_TOKEN secret on $REPO…"
gh secret set CLOUDFLARE_API_TOKEN -R "$REPO" --body "$CF_PAGES_TOKEN"

echo "→ installing deploy workflow into $REPO…"
WORKFLOW=$(cat <<YAML
name: Deploy to Cloudflare Pages
on:
  push:
    branches: [$BRANCH]
    paths: ["$DIR/**", ".github/workflows/deploy-cf-pages.yml"]
  workflow_dispatch:
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npx --yes wrangler pages deploy "$DIR" --project-name "$PROJECT" --branch "$BRANCH" --commit-dirty=true
        env:
          CLOUDFLARE_API_TOKEN: \${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: $ACCOUNT_ID
YAML
)
EXISTING_SHA=$(gh api "repos/$REPO/contents/.github/workflows/deploy-cf-pages.yml" --jq .sha 2>/dev/null || true)
gh api "repos/$REPO/contents/.github/workflows/deploy-cf-pages.yml" -X PUT \
  -f message="ci: auto-deploy $DIR to Cloudflare Pages ($PROJECT)" \
  -f content="$(printf '%s' "$WORKFLOW" | base64)" \
  ${EXISTING_SHA:+-f sha="$EXISTING_SHA"} >/dev/null

echo "✓ $REPO now auto-deploys $DIR → https://$PROJECT.pages.dev on push to $BRANCH"
echo "  Custom domain: attach once in the CF dashboard (or ask Claude — needs the DNS:Edit scope)."
