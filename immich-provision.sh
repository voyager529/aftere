#!/usr/bin/env bash
# =============================================================================
# after-e- — immich-provision.sh   [build 20]
# =============================================================================
# Connects Immich to Authentik (OIDC), and walks the operator through the two
# steps that CANNOT be automated.
#
# WHY THERE IS A MANUAL STEP AT ALL:
#   * immich-admin has no create-admin command (confirmed against the shipped
#     CLI: reset-admin-password assumes an admin already exists). The first
#     account is created through the web wizard, full stop.
#   * API keys are a per-USER setting, minted from a logged-in session. So there
#     is no key to authenticate with until a human has logged in at least once.
# Everything downstream of those two facts is automated here.
#
# ORDER (each step depends on the one before):
#   1. re-enable maintenance mode and REGENERATE the token — the token is only
#      ~4h, so echoing whatever init.sh printed would hand over a dead link.
#   2. operator opens the URL, clicks End maintenance mode, runs the wizard,
#      creates the admin, mints an API key.
#   3. this script validates the key, then PUTs the OAuth config.
#   4. immich-admin enable-oauth-login.
#
# The whole OAuth block below was proven by hand end-to-end on the 0829 box
# (hal authenticated through Authentik into Immich, auto-registered as a
# non-admin with the right storage label). It is capture, not derivation.
#
# Usage:  bash immich-provision.sh            (prompts for the API key)
#         bash immich-provision.sh <api-key>
# =============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

command -v jq >/dev/null 2>&1 || die "jq is required (run prereqs.sh)."

DOMAIN="$(getcfg AFTERE_DOMAIN || true)"
[[ -z "$DOMAIN" ]] && DOMAIN="$(getcfg AFTERE_STAGING_DOMAIN || getcfg AFTERE_PRODUCTION_DOMAIN || true)"
[[ -n "$DOMAIN" ]] || die "no domain in .env — run init.sh first."
PROFILES="$(getcfg COMPOSE_PROFILES || true)"
CONFIG_PATH="$(getcfg AFTERE_CONFIG || true)"
SECRET="$(getcfg OIDC_IMMICH_SECRET || true)"
ML_ON="$(getcfg AFTERE_IMMICH_ML || echo no)"

[[ ",$PROFILES," == *",photos,"* ]] || die "the photos profile is not deployed — nothing to provision."
[[ -n "$SECRET" ]] || die "OIDC_IMMICH_SECRET missing from .env."

BASE="https://immich.${DOMAIN}"
ISSUER="https://auth.${DOMAIN}/application/o/immich/"
DC=(docker compose)

# --- staging-cert gate -------------------------------------------------------
# Immich fetches Authentik's discovery document SERVER-SIDE with
# allowInsecureRequests=false, so an untrusted (staging) cert on auth.$DOMAIN
# makes OIDC fail with a maddeningly vague "unable to login with OAuth". Catch
# it here rather than letting the operator debug a browser error.
CERT="$CONFIG_PATH/certs/auth.$DOMAIN/fullchain.pem"
if [[ -f "$CERT" ]] && openssl x509 -issuer -noout -in "$CERT" 2>/dev/null | grep -qi "staging\|STAGING"; then
  warn "auth.$DOMAIN is on a Let's Encrypt STAGING certificate."
  warn "Immich validates that certificate when it fetches Authentik's discovery"
  warn "document, so OIDC login WILL fail until you issue real certs:"
  warn "    sudo STAGING=0 bash cert-http.sh"
  die  "refusing to configure OIDC against a staging cert."
fi

# --- 1. lock, and regenerate the token --------------------------------------
step "Locking Immich and issuing a fresh maintenance link"
MM_OUT="$("${DC[@]}" exec -T immich-server immich-admin enable-maintenance-mode 2>&1 || true)"
TOKEN="$(grep -o 'token=[A-Za-z0-9._-]*' <<<"$MM_OUT" | head -n1 | cut -d= -f2)"
if [[ -z "$TOKEN" ]]; then
  warn "couldn't parse a maintenance token. Raw output:"
  sed 's/^/    /' <<<"$MM_OUT"
  die "re-run once immich-server is healthy."
fi
# The CLI prints Immich's HOSTED domain (my.immich.app). Pasted verbatim that
# lands the operator on a page that isn't theirs.
MM_URL="${BASE}/maintenance?token=${TOKEN}"
ok "maintenance mode on — nobody can reach Immich or claim the admin account"

cat <<EOF

  ${c_bold}Immich is locked. To finish setup:${c_end}

    1. Open:
       ${c_bold}${MM_URL}${c_end}

    2. Click "End maintenance mode".

    3. Create your admin account. Use the ${c_bold}SAME email address${c_end} you'll use
       for SSO — Immich matches OAuth logins by email, so a different address
       gives you two separate accounts instead of one.
       (Keep the password. It stays as your break-glass login if SSO breaks.)

    4. The wizard will ask about place names and version checks — answer those
       however you like; after-e- deliberately doesn't ask them twice.

    5. Log in, then click your avatar (top right) -> Account Settings ->
       API Keys -> New API Key. Name it "aftere-provision" and copy the key.

    6. Come back here and paste it.

  ${c_dim}If you close this terminal, just re-run immich-provision.sh — it re-locks
  and issues a fresh link. The token above expires in about 4 hours.${c_end}

EOF
read -r -p "  Press Enter once you have the API key... " _ < /dev/tty

# --- 2. API key --------------------------------------------------------------
API_KEY="${1:-}"
if [[ -z "$API_KEY" ]]; then
  read -r -s -p "  Paste the API key: " API_KEY < /dev/tty; echo
fi
[[ -n "$API_KEY" ]] || die "no API key given."

step "Validating the key"
# Read before write: a bad paste should fail cleanly, not half-configure Immich.
CFG="$(mktemp)"; trap 'rm -f "$CFG" "$CFG.new"' EXIT
if ! curl -fsS --max-time 15 "$BASE/api/system-config" -H "x-api-key: $API_KEY" > "$CFG" 2>/dev/null; then
  die "the API rejected that key (or Immich is still locked — did you click End maintenance mode?)."
fi
jq -e . "$CFG" >/dev/null 2>&1 || die "the API returned something that isn't JSON."
ok "key accepted"

# --- 3. system-config --------------------------------------------------------
# NOTE: /api/system-config is a WHOLE-DOCUMENT PUT, not a patch. Sending only the
# oauth key would wipe every other setting, so this is read-modify-write.
step "Writing the OIDC configuration"
ML_FLAG=false; [[ "$ML_ON" == yes ]] && ML_FLAG=true

jq --arg sec "$SECRET" --arg iss "$ISSUER" --arg ext "$BASE" --argjson ml "$ML_FLAG" '
  .oauth.enabled            = true |
  .oauth.clientId           = "immich" |
  .oauth.clientSecret       = $sec |
  .oauth.issuerUrl          = $iss |
  .oauth.autoRegister       = true |
  .oauth.buttonText         = "Login with after-e-" |
  .oauth.scope              = "openid email profile" |
  .server.externalDomain    = $ext |
  .machineLearning.enabled  = $ml
' "$CFG" > "$CFG.new" || die "failed to build the new config."

if ! curl -fsS --max-time 20 -X PUT "$BASE/api/system-config" \
     -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
     -d @"$CFG.new" > "$CFG.res" 2>/dev/null; then
  die "the system-config PUT failed — Immich is unchanged."
fi
ok "oauth configured (issuer: $ISSUER)"
ok "externalDomain: $BASE"
# machineLearning.enabled has to match the DEPLOY, not the default: with the
# immich-ml profile off there is no container behind the configured URL.
[[ "$ML_FLAG" == true ]] && ok "machine learning: on" || ok "machine learning: off (immich-ml not deployed)"

# --- 4. flip the switch ------------------------------------------------------
step "Enabling OAuth login"
"${DC[@]}" exec -T immich-server immich-admin enable-oauth-login >/dev/null 2>&1 \
  && ok "OAuth login enabled" \
  || warn "enable-oauth-login reported a problem — check: ${DC[*]} exec immich-server immich-admin help"

cat <<EOF

  ${c_bold}Done.${c_end} Sign in at ${BASE} with the "Login with after-e-" button.

  Users auto-register on first SSO login, as non-admins, with their Authentik
  username as the Immich storage label.

  Password login is deliberately LEFT ON so your admin account stays a
  break-glass route. Once SSO is proven, you can turn it off with:
      ${DC[*]} exec immich-server immich-admin disable-password-login

  If Immich is ever locked and you have no browser link handy:
      ${DC[*]} exec immich-server immich-admin disable-maintenance-mode

EOF
