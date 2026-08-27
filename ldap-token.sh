#!/usr/bin/env bash
# =============================================================================
# after-e- — ldap-token.sh
# =============================================================================
# Authentik doesn't let you set an outpost's token (issue #9711). The outpost's
# token is auto-generated when the blueprint creates the outpost. This reads
# that token back via the admin API and feeds it to the authentik-ldap
# container, then restarts it so it authenticates (goes from 403 -> healthy).
#
# Runnable standalone (re-run any time) and called by init.sh after bring-up.
# Requires: the stack up, auth.$DOMAIN served, and the aftere-ldap blueprint
# applied (System -> Blueprints shows it green).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root."
command -v jq >/dev/null 2>&1 || die "jq missing (run prereqs.sh)."

TOKEN="$(getcfg AUTHENTIK_BOOTSTRAP_TOKEN || true)"; [[ -n "$TOKEN" ]] || die "no AUTHENTIK_BOOTSTRAP_TOKEN in .env."
DOMAIN="$(getcfg AFTERE_DOMAIN || true)"; [[ -n "$DOMAIN" ]] || die "no AFTERE_DOMAIN in .env."
API="https://auth.${DOMAIN}/api/v3"

akget() { curl -sk --connect-timeout 5 --max-time 25 -H "Authorization: Bearer $TOKEN" "$API$1"; }

# Don't fire at the API until it actually serves JSON (fresh-bring-up race).
wait_for_authentik_api "$API" "$TOKEN"

# --- 1. wait for the outpost the blueprint creates --------------------------
step "Locating the aftere-ldap outpost"
deadline=$(( SECONDS + 180 )); uuid=""; tokid=""
while :; do
  resp="$(akget "/outposts/instances/" || true)"
  uuid="$(printf '%s' "$resp"  | jq -r '.results[]? | select(.name=="aftere-ldap") | .pk' | head -n1)"
  tokid="$(printf '%s' "$resp" | jq -r '.results[]? | select(.name=="aftere-ldap") | .token_identifier' | head -n1)"
  [[ -n "$uuid" && -n "$tokid" ]] && break
  (( SECONDS > deadline )) && die "aftere-ldap outpost never appeared — check System -> Blueprints for a 20-ldap error."
  sleep 5
done
ok "outpost found (pk=$uuid)"

# --- 2. read its auto-generated token ---------------------------------------
step "Reading the outpost's token"
key="$(akget "/core/tokens/${tokid}/view_key/" | jq -r '.key // empty')"
[[ -n "$key" ]] || die "could not read the outpost token (identifier=$tokid)."
ok "token retrieved"

# --- 3. write it to .env (do NOT restart here) ------------------------------
# ldap-bind.sh performs the single authoritative outpost restart at the end of
# its run (after the direct-mode config is read-back-verified), recreating the
# container so it picks up BOTH this token and the current provider config in one
# go. Restarting here too caused a second restart that raced ldap-bind's API
# calls (jq parse errors on the proxy blip). So: write the token, stop there.
step "Injecting token into .env"
sed -i "/^AUTHENTIK_LDAP_TOKEN=/d" "$ENV_FILE"
printf "AUTHENTIK_LDAP_TOKEN='%s'\n" "$key" >> "$ENV_FILE"
ok "token written — ldap-bind.sh will restart authentik-ldap to apply it"
ok "  (standalone? apply it now with: docker compose up -d --force-recreate authentik-ldap)"
