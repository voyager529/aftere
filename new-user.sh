#!/usr/bin/env bash
# =============================================================================
# after-e- — new-user.sh
# =============================================================================
# Creates/updates a user in Authentik (the identity source of truth) and issues
# a credential. Apps provision just-in-time off OIDC/LDAP on first login, so the
# ONLY place a user is created is here.
#
# Reaches Authentik's REST API over https://auth.$DOMAIN (through nginx) using
# the bootstrap admin token from .env — no sidecar container, no host port.
#
# Credential options:
#   - recovery link (default): user sets their own password + can enroll MFA.
#     Production-correct. Reuses `ak create_recovery_key` (minutes-based).
#   - set password now: handy for testing IMAP/OIDC login with known creds.
#
# Identity split (dormant until the staging/production questionnaire lands):
#   if AFTERE_STAGING_DOMAIN is set, offers a THROWAWAY test user at the staging
#   domain (delete at cutover) vs a real user at the production identity. With
#   no staging domain it's vanilla: user@AFTERE_DOMAIN.
#
# Usage:
#   new-user.sh                 interactive, single user
#   new-user.sh --admin         interactive, also add to aftere-admins
#   new-user.sh --csv FILE      batch: lines of  username,Full Name,email[,admin]
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root (needs docker compose exec)."
command -v jq   >/dev/null 2>&1 || die "jq missing (run prereqs.sh)."
command -v curl >/dev/null 2>&1 || die "curl missing (run prereqs.sh)."

# --- config -----------------------------------------------------------------
TOKEN="$(getcfg AUTHENTIK_BOOTSTRAP_TOKEN || true)"; [[ -n "$TOKEN" ]] || die "no AUTHENTIK_BOOTSTRAP_TOKEN in .env."
DOMAIN="$(getcfg AFTERE_DOMAIN || true)"; [[ -n "$DOMAIN" ]] || die "no AFTERE_DOMAIN in .env."
STAGING_DOMAIN="$(getcfg AFTERE_STAGING_DOMAIN || true)"
PROD_DOMAIN="$(getcfg AFTERE_PRODUCTION_DOMAIN || echo "$DOMAIN")"
AUTH_URL="https://auth.${DOMAIN}"
API="${AUTH_URL}/api/v3"

CSV=""; WANT_ADMIN=no
while [[ $# -gt 0 ]]; do case "$1" in
  --csv) CSV="${2:-}"; shift 2 ;;
  --admin) WANT_ADMIN=yes; shift ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) die "unknown arg: $1" ;;
esac; done

# --- API helper: sets HTTP_CODE + HTTP_BODY ---------------------------------
akcall() {
  local method="$1" path="$2" data="${3:-}" out
  local args=(-sk --connect-timeout 5 --max-time 25 -X "$method" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -w $'\n%{http_code}')
  [[ -n "$data" ]] && args+=(-d "$data")
  out="$(curl "${args[@]}" "${API}${path}")" || die "cannot reach $API within timeout — is the stack fully up and auth.$DOMAIN served? (init may have aborted before bring-up finished)"
  HTTP_CODE="${out##*$'\n'}"; HTTP_BODY="${out%$'\n'*}"
}

# --- preflight: Authentik reachable + resolve group PKs ---------------------
step "Checking Authentik"
akcall GET "/core/groups/?name=aftere-users"
[[ "$HTTP_CODE" == 200 ]] || die "Authentik API returned $HTTP_CODE (token valid? blueprints applied?)."
GID_USERS="$(echo "$HTTP_BODY" | jq -r '.results[0].pk // empty')"
[[ -n "$GID_USERS" ]] || die "group 'aftere-users' not found — did the group blueprint apply?"
akcall GET "/core/groups/?name=aftere-admins"
GID_ADMINS="$(echo "$HTTP_BODY" | jq -r '.results[0].pk // empty')"
ok "connected; groups resolved"

# --- ordering guard (qa_14): mail backend must be provisioned first ----------
# Running new-user.sh BEFORE stalwart-provision.sh silently creates a user whose
# mailbox won't work, and the failure reads like a login bug rather than an
# ordering mistake (a full afternoon lost to exactly this). Guard at the source.
# Signals are cheap + reliable and don't guess stalwart-cli output: ldap-bind ran
# (LDAP_BIND_PASSWORD in .env) AND provision ran (it writes plan-systemsettings
# .json near the end, after the directory + SystemSettings applies succeed).
if [[ ",$(getcfg COMPOSE_PROFILES 2>/dev/null)," == *",mail,"* ]] && [[ "${AFTERE_SKIP_MAILCHECK:-0}" != 1 ]]; then
  step "Checking the mail backend is provisioned"
  _cfg="$(getcfg AFTERE_CONFIG 2>/dev/null || echo /mnt/aftere/config)"
  if [[ -z "$(getcfg LDAP_BIND_PASSWORD 2>/dev/null || true)" || ! -f "${_cfg}/stalwart/plan-systemsettings.json" ]]; then
    echo "  The mail backend isn't provisioned yet. Run stalwart-provision.sh BEFORE new-user.sh —"
    echo "  a user created now would have a non-working mailbox until you do, and that failure"
    echo "  looks like a login bug, not an ordering one."
    die "run stalwart-provision.sh first  (or set AFTERE_SKIP_MAILCHECK=1 for an OIDC-only user, no mailbox)."
  fi
  ok "mail backend provisioned"
fi

# --- core ops ---------------------------------------------------------------
NEW_PK=""
create_user() {           # username  name  email  want_admin
  local username="$1" name="$2" email="$3" admin="$4" groups payload pk
  if [[ "$admin" == yes && -n "$GID_ADMINS" ]]; then
    groups="$(jq -n --arg u "$GID_USERS" --arg a "$GID_ADMINS" '[$u,$a]')"
  else
    groups="$(jq -n --arg u "$GID_USERS" '[$u]')"
  fi
  akcall GET "/core/users/?username=${username}"
  pk="$(echo "$HTTP_BODY" | jq -r '.results[0].pk // empty')"
  if [[ -n "$pk" ]]; then
    warn "user '$username' already exists (pk=$pk) — updating name/email/groups."
    payload="$(jq -n --arg n "$name" --arg e "$email" --argjson g "$groups" '{name:$n,email:$e,groups:$g}')"
    akcall PATCH "/core/users/${pk}/" "$payload"
    [[ "$HTTP_CODE" =~ ^2 ]] || { bad "update failed ($HTTP_CODE): $HTTP_BODY"; return 1; }
  else
    payload="$(jq -n --arg u "$username" --arg n "$name" --arg e "$email" --argjson g "$groups" \
      '{username:$u,name:$n,email:$e,type:"internal",is_active:true,path:"users",groups:$g}')"
    akcall POST "/core/users/" "$payload"
    [[ "$HTTP_CODE" =~ ^2 ]] || { bad "create failed ($HTTP_CODE): $HTTP_BODY"; return 1; }
    pk="$(echo "$HTTP_BODY" | jq -r '.pk')"
  fi
  NEW_PK="$pk"; return 0
}

set_password() {          # pk  password
  akcall POST "/core/users/$1/set_password/" "$(jq -n --arg p "$2" '{password:$p}')"
  [[ "$HTTP_CODE" =~ ^2 ]] || { bad "set_password failed ($HTTP_CODE): $HTTP_BODY"; return 1; }
}

recovery_link() {         # username -> prints an https://auth.$DOMAIN/... URL
  local raw path
  cd "$REPO_BASE"
  # create_recovery_key duration is in MINUTES as of Authentik 2025.10.
  raw="$(docker compose exec -T authentik-worker ak create_recovery_key 60 "$1" 2>/dev/null || true)"
  path="$(echo "$raw" | grep -oE '/if/flow/[^ ]+' | head -n1)"
  [[ -n "$path" ]] && echo "${AUTH_URL}${path}" || echo ""
}

# --- CSV batch mode ---------------------------------------------------------
if [[ -n "$CSV" ]]; then
  [[ -r "$CSV" ]] || die "cannot read CSV: $CSV"
  step "Batch provisioning from $CSV (recovery links)"
  printf '\n  %s──── credentials below (save then scrub) ────%s\n' "$c_warn" "$c_end"
  while IFS=, read -r u n e adminflag; do
    [[ -z "${u// }" || "${u:0:1}" == "#" ]] && continue
    u="${u// }"; e="${e// }"; adminflag="${adminflag// }"
    if create_user "$u" "$n" "$e" "$([[ "$adminflag" == admin ]] && echo yes || echo no)"; then
      link="$(recovery_link "$u")"
      printf '    %-20s %-30s %s\n' "$u" "$e" "${link:-<recovery link failed; check auth URL>}"
    fi
  done < "$CSV"
  printf '  %s──── credentials above ────%s\n' "$c_warn" "$c_end"
  ok "batch done"; exit 0
fi

# --- interactive single user ------------------------------------------------
step "New user"
EMAIL_DOMAIN="$PROD_DOMAIN"; IS_TEST=no
if [[ -n "$STAGING_DOMAIN" ]]; then
  echo "  A staging domain is configured. Which kind of user?"
  echo "    1) Real user      — production identity (@${PROD_DOMAIN})"
  echo "    2) Throwaway TEST — staging identity (@${STAGING_DOMAIN}); delete at cutover"
  read -r -p "  choice [1-2]: " k < /dev/tty
  [[ "$k" == 2 ]] && { EMAIL_DOMAIN="$STAGING_DOMAIN"; IS_TEST=yes; }
fi

read -r -p "  Username (login): " USERNAME < /dev/tty
[[ -n "$USERNAME" ]] || die "username required."
read -r -p "  Full name: " FULLNAME < /dev/tty
read -r -p "  Email [${USERNAME}@${EMAIL_DOMAIN}]: " EMAIL < /dev/tty
EMAIL="${EMAIL:-${USERNAME}@${EMAIL_DOMAIN}}"
if [[ "$WANT_ADMIN" != yes ]]; then
  read -r -p "  Grant admin (aftere-admins)? [y/N]: " a < /dev/tty
  [[ "$a" =~ ^[Yy] ]] && WANT_ADMIN=yes
fi

create_user "$USERNAME" "$FULLNAME" "$EMAIL" "$WANT_ADMIN" || die "user provisioning failed."
ok "user '${USERNAME}' ready (pk=${NEW_PK}${IS_TEST:+, TEST})"

echo "  Credential:"
echo "    1) Generate a recovery link — printed here; hand it to the user (expires 60 min) [default]"
echo "    2) Set a password now (handy for testing login)"
read -r -p "  choice [1-2]: " c < /dev/tty
printf '\n  %s──── credentials below (save then scrub) ────%s\n' "$c_warn" "$c_end"
if [[ "$c" == 2 ]]; then
  read -rs -p "  Password: " PW < /dev/tty; echo
  if set_password "$NEW_PK" "$PW"; then
    printf '    user:  %s\n    login: %s\n    pass:  (the one you just entered)\n' "$USERNAME" "$AUTH_URL"
  fi
  unset PW
else
  LINK="$(recovery_link "$USERNAME")"
  if [[ -n "$LINK" ]]; then
    printf '    user:  %s\n    set-password link (valid ~60 min, single use):\n    %s\n' "$USERNAME" "$LINK"
  else
    warn "recovery link generation failed — check that auth.$DOMAIN is served and the worker is up."
  fi
fi
printf '  %s──── credentials above ────%s\n' "$c_warn" "$c_end"

echo
echo "  This account can now log in at ${AUTH_URL} and (once app-side OIDC/LDAP"
echo "  is wired in postinstall) at Nextcloud / Immich / Vault and IMAP via Roundcube."
