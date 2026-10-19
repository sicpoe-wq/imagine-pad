#!/usr/bin/env bash
# Deploy the Imagine Pad Worker.
# Needs: CLOUDFLARE_API_TOKEN (Workers Scripts:Edit + Workers AI:Read, account-scoped)
#        CLOUDFLARE_ACCOUNT_ID
#        APP_SHARED_SECRET (any long random string; also given to the app)
set -euo pipefail
cd "$(dirname "$0")"
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"
: "${APP_SHARED_SECRET:?set APP_SHARED_SECRET (e.g. openssl rand -hex 24)}"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

node --test test/
npx --yes wrangler@4 deploy
printf '%s' "$APP_SHARED_SECRET" | npx --yes wrangler@4 secret put APP_SHARED_SECRET
echo
echo "Deployed. Test with:"
echo "  curl -s -H \"X-App-Secret: \$APP_SHARED_SECRET\" https://imagine-pad.<your-subdomain>.workers.dev/health"
