#!/usr/bin/env bash
# ─── One-shot deploy for the MCC CAPS AI Claude proxy ──────────────────
# Handles: install, login, secret, allowed-origins, deploy, client wiring.
# Re-runnable — safe to invoke again for re-deploys or key rotations.

set -e
cd "$(dirname "$0")"

GOLD="\033[38;5;179m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
RESET="\033[0m"

step()  { printf "\n${GOLD}▸ %s${RESET}\n" "$*"; }
info()  { printf "${DIM}  %s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}  ✓ %s${RESET}\n" "$*"; }
die()   { printf "${RED}  ✗ %s${RESET}\n" "$*"; exit 1; }

# ─── 1. Install Wrangler if missing ────────────────────────────────────
if [ ! -d node_modules ]; then
  step "Installing Wrangler"
  npm install --silent
  ok "Wrangler installed"
else
  ok "Wrangler already installed"
fi

# ─── 2. Cloudflare login ───────────────────────────────────────────────
step "Cloudflare account"
if npx --no-install wrangler whoami >/dev/null 2>&1; then
  ACCOUNT=$(npx --no-install wrangler whoami 2>/dev/null | grep -oE '[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+' | head -1 || echo "logged in")
  ok "Signed in as $ACCOUNT"
else
  info "Not signed in — opening browser for Cloudflare OAuth..."
  npx wrangler login
  ok "Signed in"
fi

# ─── 3. Allowed origins ────────────────────────────────────────────────
step "Production domain(s)"
CURRENT_ORIGINS=$(grep -E '^ALLOWED_ORIGINS' wrangler.toml | sed -E 's/^ALLOWED_ORIGINS = "(.*)"/\1/')
if [ -n "$CURRENT_ORIGINS" ] && ! echo "$CURRENT_ORIGINS" | grep -q "your-site.com"; then
  info "Current: $CURRENT_ORIGINS"
  read -rp "  Keep this? [Y/n] " KEEP
  if [ "$KEEP" = "n" ] || [ "$KEEP" = "N" ]; then
    CURRENT_ORIGINS=""
  fi
fi
if [ -z "$CURRENT_ORIGINS" ] || echo "$CURRENT_ORIGINS" | grep -q "your-site.com"; then
  echo "  Where will the pitch site be hosted?"
  echo "  Enter one or more URLs, comma-separated. Example:"
  echo "    https://pitch.mcc.gov.ae"
  echo "    https://pitch.mcc.gov.ae,https://staging-pitch.mcc.gov.ae"
  read -rp "  ALLOWED_ORIGINS: " ORIGINS
  [ -z "$ORIGINS" ] && die "No domain given"
  # Basic validation: must start with https:// (or http:// for localhost only)
  echo "$ORIGINS" | tr ',' '\n' | while read -r u; do
    u=$(echo "$u" | xargs)
    case "$u" in
      https://*|http://localhost*|http://127.0.0.1*) ;;
      *) die "'$u' is not a valid origin — must start with https://" ;;
    esac
  done
  perl -i -pe "s|^ALLOWED_ORIGINS = \".*\"|ALLOWED_ORIGINS = \"$ORIGINS\"|" wrangler.toml
  ok "Wrote allowed origins to wrangler.toml"
else
  ok "Using existing allowed origins"
fi

# ─── 4. Anthropic secret ───────────────────────────────────────────────
step "Anthropic API key"
EXISTING_SECRETS=$(npx --no-install wrangler secret list 2>/dev/null || echo "[]")
if echo "$EXISTING_SECRETS" | grep -q ANTHROPIC_API_KEY; then
  info "ANTHROPIC_API_KEY already set"
  read -rp "  Rotate it now? [y/N] " ROTATE
  if [ "$ROTATE" = "y" ] || [ "$ROTATE" = "Y" ]; then
    echo "  Paste the new key (input hidden):"
    read -rs KEY
    echo
    [ -z "$KEY" ] && die "No key given"
    case "$KEY" in sk-ant-*) ;; *) die "Key should start with sk-ant-" ;; esac
    printf "%s" "$KEY" | npx --no-install wrangler secret put ANTHROPIC_API_KEY
    ok "Key rotated"
  else
    ok "Keeping existing key"
  fi
else
  echo "  Paste your Anthropic API key (input hidden):"
  read -rs KEY
  echo
  [ -z "$KEY" ] && die "No key given"
  case "$KEY" in sk-ant-*) ;; *) die "Key should start with sk-ant-" ;; esac
  printf "%s" "$KEY" | npx --no-install wrangler secret put ANTHROPIC_API_KEY
  ok "Key uploaded to Cloudflare secret store"
fi

# ─── 5. Deploy ─────────────────────────────────────────────────────────
step "Deploying Worker"
DEPLOY_LOG=$(mktemp)
if ! npx --no-install wrangler deploy 2>&1 | tee "$DEPLOY_LOG"; then
  die "Deploy failed — see output above"
fi
URL=$(grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' "$DEPLOY_LOG" | head -1)
rm -f "$DEPLOY_LOG"
[ -z "$URL" ] && die "Could not parse Worker URL from deploy output"
ok "Deployed: $URL"

# ─── 6. Wire the pitch site ────────────────────────────────────────────
step "Wiring index-mcc.html"
if [ ! -f ../index-mcc.html ]; then
  die "Can't find ../index-mcc.html (are you running from /worker?)"
fi
if ! grep -q "PROD_CLAUDE_PROXY_URL" ../index-mcc.html; then
  die "PROD_CLAUDE_PROXY_URL not found in index-mcc.html — was the template changed?"
fi
perl -i -pe "s|const PROD_CLAUDE_PROXY_URL\s*=\s*'[^']*';|const PROD_CLAUDE_PROXY_URL  = '$URL';|" ../index-mcc.html
ok "index-mcc.html now points at the deployed Worker"

# ─── 7. Smoke test ─────────────────────────────────────────────────────
step "Smoke test"
FIRST_ORIGIN=$(echo "${ORIGINS:-$CURRENT_ORIGINS}" | cut -d',' -f1 | xargs)
info "Testing from origin: $FIRST_ORIGIN"
HTTP=$(curl -s -o /tmp/mcc-smoke.json -w "%{http_code}" -X POST \
  -H "Origin: $FIRST_ORIGIN" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":30,"messages":[{"role":"user","content":"reply with just the word: ready"}]}' \
  "$URL")
if [ "$HTTP" = "200" ]; then
  REPLY=$(cat /tmp/mcc-smoke.json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["content"][0]["text"].strip())' 2>/dev/null || echo "(parsed)")
  ok "Worker responded 200 OK · Claude said: $REPLY"
else
  printf "${RED}  ✗ Worker returned HTTP %s${RESET}\n" "$HTTP"
  cat /tmp/mcc-smoke.json 2>/dev/null
  echo
  info "Most common cause: ALLOWED_ORIGINS doesn't match the hosting URL."
fi
rm -f /tmp/mcc-smoke.json

# ─── 8. Summary ────────────────────────────────────────────────────────
step "Done"
cat <<EOF
  ${GREEN}Worker URL:${RESET}     $URL
  ${GREEN}Allowed origins:${RESET} ${ORIGINS:-$CURRENT_ORIGINS}
  ${GREEN}Client wired:${RESET}   index-mcc.html → PROD_CLAUDE_PROXY_URL

  Open the pitch site from one of the allowed origins and the AI
  assistant status pill will show "LIVE · CLAUDE" automatically.

  To rotate the key later:   ./deploy.sh   (answer Y at the rotate prompt)
  To watch live Worker logs: npx wrangler tail
EOF
