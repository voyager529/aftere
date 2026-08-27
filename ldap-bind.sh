#!/usr/bin/env bash
# =============================================================================
# after-e- — ldap-bind.sh
# =============================================================================
# The aftere-ldap-bind service account (created by 20-ldap.yaml) needs an
# app-password for Stalwart to bind with. Like the outpost token, the key is
# generated server-side and can't be injected via blueprint — so we create the
# app-password via the API and read its key back into LDAP_BIND_PASSWORD.
#
# Idempotent + re-runnable. init.sh calls it after blueprints apply; the value
# is then consumed by stalwart-provision.sh as the directory bind secret.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root."
command -v jq >/dev/null 2>&1 || die "jq missing (run prereqs.sh)."

TOKEN="$(getcfg AUTHENTIK_BOOTSTRAP_TOKEN || true)"; [[ -n "$TOKEN" ]] || die "no AUTHENTIK_BOOTSTRAP_TOKEN in .env."
DOMAIN="$(getcfg AFTERE_DOMAIN || true)"; [[ -n "$DOMAIN" ]] || die "no AFTERE_DOMAIN in .env."
API="https://auth.${DOMAIN}/api/v3"
IDENT="aftere-ldap-bind-password"

akcall() { # METHOD PATH [JSON]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then
    curl -sk --connect-timeout 5 --max-time 25 -X "$m" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$d" "$API$p"
  else
    curl -sk --connect-timeout 5 --max-time 25 -X "$m" -H "Authorization: Bearer $TOKEN" "$API$p"
  fi
}

# Don't fire at the API until it actually serves JSON (fresh-bring-up race).
wait_for_authentik_api "$API" "$TOKEN"

# 1. find the bind service account (created by the blueprint)
step "Locating aftere-ldap-bind service account"
uid="$(akcall GET "/core/users/?username=aftere-ldap-bind" | jq -r '.results[0].pk // empty')"
[[ -n "$uid" ]] || die "aftere-ldap-bind not found — did the 20-ldap blueprint apply? (check System -> Blueprints)"
ok "found (pk=$uid)"

# 1b. ensure the bind account is a MEMBER of ldap-search-group.
# The 20-ldap.yaml blueprint builds role->group and lists the bind user in the
# group's ak_groups, but that membership does NOT take on a fresh apply because
# the account is a service_account whose group wiring is unreliable at blueprint
# time (proven qa_10/aftere-0811: group existed, held the role, but had zero
# members -> bind account had search_full_directory = False -> Stalwart bound OK
# but every user search returned nothing -> Roundcube login failed). Wiring the
# membership HERE, where the account demonstrably exists, is the reliable fix
# (same "wire it where it's created" pattern as the token/app-password read-back).
step "Adding aftere-ldap-bind to ldap-search-group (search permission)"
# ldap-bind.sh can run before the 20-ldap blueprint has finished creating the
# group (proven qa_11/aftere-0812: first run silently missed -> bind acct had no
# search perm -> hal login failed; a manual re-run then joined fine). So poll for
# the group instead of giving up on the first miss.
gid=""
for attempt in $(seq 1 20); do
  gid="$(akcall GET "/core/groups/?name=ldap-search-group" | jq -r '.results[0].pk // empty')"
  [[ -n "$gid" ]] && break
  [[ $attempt -eq 1 ]] && printf '    waiting for ldap-search-group (blueprint apply)'
  printf '.'; sleep 3
done
[[ $attempt -gt 1 ]] && printf '\n'
if [[ -z "$gid" ]]; then
  warn "ldap-search-group not found after ~60s — did 20-ldap apply? search perm will be missing."
else
  # PATCH the group's users list to include this uid (idempotent: add if absent).
  current="$(akcall GET "/core/groups/${gid}/" | jq -c '.users // []')"
  if printf '%s' "$current" | jq -e --argjson u "$uid" 'index($u)' >/dev/null 2>&1; then
    ok "already a member of ldap-search-group"
  else
    newlist="$(printf '%s' "$current" | jq -c --argjson u "$uid" '. + [$u]')"
    akcall PATCH "/core/groups/${gid}/" "{\"users\":${newlist}}" >/dev/null \
      && ok "joined ldap-search-group" \
      || warn "could not add bind account to ldap-search-group — search may fail."
  fi
fi

# 2. ensure an app-password token exists for it (create if missing)
step "Ensuring app-password"
exists="$(akcall GET "/core/tokens/?identifier=${IDENT}" | jq -r '.results[0].identifier // empty')"
if [[ -z "$exists" ]]; then
  akcall POST "/core/tokens/" \
    "{\"identifier\":\"${IDENT}\",\"user\":${uid},\"intent\":\"app_password\",\"expiring\":false,\"description\":\"Stalwart LDAP bind\"}" \
    >/dev/null || die "could not create app-password."
  ok "app-password created"
else
  ok "app-password already exists"
fi

# 3. read the key back
key="$(akcall GET "/core/tokens/${IDENT}/view_key/" | jq -r '.key // empty')"
[[ -n "$key" ]] || die "could not read app-password key."

# 4. write it to .env (single-quoted, like other secrets)
sed -i "/^LDAP_BIND_PASSWORD=/d" "$ENV_FILE"
printf "LDAP_BIND_PASSWORD='%s'\n" "$key" >> "$ENV_FILE"
ok "LDAP_BIND_PASSWORD set from the bind account's app-password"

# 4b. READ THE PROVIDER CONFIG BACK and verify the three fields that silently
# broke login for two weeks actually hold their intended values. The 20-ldap
# blueprint WRITES bind_mode/search_mode/authentication_flow, but until now
# nothing confirmed they took — and every root cause of the saga was one of these
# quietly holding the wrong value (bind_flow ignored -> auth flow None; cached
# mode -> stale binds -> LDAP 49/50). Reading them from the DB here makes a bad
# apply fail LOUD and named, instead of resurfacing days later as a misleading
# "invalid credentials". This is the same read-back discipline stalwart-provision
# uses for SystemSettings — applied to the one high-risk apply that historically
# lied to us.
#
# Deliberately WARN, not die: the exact API representation of these fields hasn't
# been confirmed against a live box, so a strict equality die could false-block a
# good deploy. It prints what it actually read either way — once a fresh run
# confirms the representation, this can be tightened to a hard die.
step "Verifying LDAP provider config (read-back)"
prov="$(akcall GET "/providers/ldap/?name=aftere-ldap" 2>/dev/null || true)"
bm="$(printf '%s' "$prov" | jq -r '.results[0].bind_mode // empty'          2>/dev/null || true)"
sm="$(printf '%s' "$prov" | jq -r '.results[0].search_mode // empty'        2>/dev/null || true)"
af="$(printf '%s' "$prov" | jq -r '.results[0].authentication_flow // empty' 2>/dev/null || true)"
if [[ -z "$bm$sm$af" ]]; then
  warn "couldn't read the LDAP provider back to verify (API returned nothing usable)."
  warn "check by hand: bind_mode + search_mode should be 'direct', authentication_flow must be set."
else
  printf '    read back: bind_mode=%s  search_mode=%s  authentication_flow=%s\n' \
    "${bm:-<unset>}" "${sm:-<unset>}" "${af:-<unset>}"
  _pv=0
  [[ "$bm" == direct ]] || { warn "bind_mode is '${bm:-<unset>}', expected 'direct' — cached mode served stale binds for two weeks (LDAP 49/50)."; _pv=1; }
  [[ "$sm" == direct ]] || { warn "search_mode is '${sm:-<unset>}', expected 'direct'."; _pv=1; }
  [[ -n "$af" ]]        || { warn "authentication_flow is unset — the outpost has no flow to run binds through; every bind fails with error 49 (the bind_flow-vs-authentication_flow bug)."; _pv=1; }
  if [[ "$_pv" == 0 ]]; then
    ok "provider verified: bind_mode/search_mode=direct, authentication_flow present"
  else
    warn "LDAP provider is NOT in the state login needs — the 20-ldap blueprint may not have"
    warn "applied these fields on this box. Fix them (GUI: Providers -> aftere-ldap) or re-apply"
    warn "the blueprint before expecting Roundcube to work; restarting the outpost can't fix a"
    warn "DB that's wrong."
  fi
fi

# 5. restart the LDAP outpost so it reloads provider config from the DB AND picks
# up the token ldap-token.sh wrote to .env. This is now the SINGLE authoritative
# restart (token.sh no longer restarts). --force-recreate is required: a plain
# `restart` reuses the running container and would NOT re-read .env, so the new
# AUTHENTIK_LDAP_TOKEN wouldn't load. Recreating also drops the outpost's cached
# provider settings (bind_mode/search_mode/flow) so direct-mode config takes —
# skipping this was a major cause of the two-week login saga.
step "Restarting LDAP outpost to load token + current provider config"
cd "$REPO_BASE"
if docker compose up -d --force-recreate authentik-ldap >/dev/null 2>&1; then
  ok "outpost recreated"
else
  warn "could not recreate authentik-ldap — do it manually: docker compose up -d --force-recreate authentik-ldap"
fi

# wait for the outpost to report healthy before returning, so stalwart-provision
# doesn't bind against a still-restarting outpost. warn-not-die: a slow box
# shouldn't hard-fail the whole run over a health poll.
step "Waiting for authentik-ldap to report healthy"
_deadline=$(( SECONDS + 90 ))
while :; do
  _st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealthcheck{{end}}' aftere-authentik-ldap 2>/dev/null || echo unknown)"
  case "$_st" in
    healthy|nohealthcheck) ok "outpost healthy"; break ;;
  esac
  (( SECONDS > _deadline )) && { warn "outpost not healthy after 90s — check: docker compose logs authentik-ldap"; break; }
  sleep 3
done
