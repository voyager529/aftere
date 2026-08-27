#!/usr/bin/env bash
# =============================================================================
# after-e- — nextcloud-provision.sh   (rev 2)
# =============================================================================
# Brings a fresh Nextcloud to the proven 0820 state, headless:
#   1. Install NC non-interactively (admin auto-created; NO exposed web wizard)
#   2. Reverse-proxy / URL settings (correct https URLs behind nginx)
#   3. LDAP against the Authentik outpost (captured, group-gated, uid-pinned)
#   4. Enable the sane app set; wipe the sample-file skeleton
#
# rev 2 fixes (found by testing against a WIPED user_ldap on 0820):
#   * getenv no longer aborts the script when a .env key is absent (pipefail trap)
#   * self-heals missing NEXTCLOUD_ADMIN_* by generating + persisting them
#     (init.sh currently doesn't render those into .env — build-17 fix noted)
#
# Idempotent + re-runnable. Run from repo root (next to .env):
#   sudo bash nextcloud-provision.sh
# -----------------------------------------------------------------------------
# DEFERRED (need their own capture): External Sites launcher tiles, Theming
# brand, and new-user.sh's "provision without first login" hook.
# =============================================================================
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f .env ]] || { echo "FATAL: no .env here — run from the repo root."; exit 1; }

# getenv: NEVER abort on a missing key. `|| true` swallows grep's non-zero so a
# missing key yields "" instead of killing the script under `set -e`/pipefail.
getenv() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"" || true; }

DOMAIN="$(getenv AFTERE_DOMAIN)"; [[ -z "$DOMAIN" ]] && DOMAIN="$(getenv DOMAIN)"
PG_NC_PW="$(getenv PG_NEXTCLOUD_PASSWORD)"
LDAP_BIND_PW="$(getenv LDAP_BIND_PASSWORD)"
NC_ADMIN_USER="$(getenv NEXTCLOUD_ADMIN_USER)"
NC_ADMIN_PW="$(getenv NEXTCLOUD_ADMIN_PASSWORD)"

[[ -n "$DOMAIN"      ]] || { echo "FATAL: DOMAIN missing in .env"; exit 1; }
[[ -n "$PG_NC_PW"    ]] || { echo "FATAL: PG_NEXTCLOUD_PASSWORD missing in .env"; exit 1; }
[[ -n "$LDAP_BIND_PW" ]] || { echo "FATAL: LDAP_BIND_PASSWORD missing in .env (LDAP half needs it)"; exit 1; }

occ() { docker compose exec -T -u www-data nextcloud php occ "$@"; }
say() { printf '\n==> %s\n' "$*"; }
gen() { LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 24 || true; }

# =============================================================================
# 1. HEADLESS INSTALL  (closes the "first visitor to the wizard becomes admin"
#    window). Only runs if NC isn't installed yet.
# =============================================================================
if occ status 2>/dev/null | grep -q 'installed: true'; then
  say "Nextcloud already installed — skipping install"
else
  # self-heal: init.sh doesn't currently write NEXTCLOUD_ADMIN_* to .env, so
  # generate + persist them here rather than fail (build-17: fix in init.sh).
  if [[ -z "$NC_ADMIN_USER" ]]; then
    NC_ADMIN_USER="ncadmin"
    echo "NEXTCLOUD_ADMIN_USER='$NC_ADMIN_USER'" >> .env
    echo "  (.env had no NEXTCLOUD_ADMIN_USER — set to '$NC_ADMIN_USER' and persisted)"
  fi
  if [[ -z "$NC_ADMIN_PW" ]]; then
    NC_ADMIN_PW="$(gen)"
    echo "NEXTCLOUD_ADMIN_PASSWORD='$NC_ADMIN_PW'" >> .env
    echo "  (.env had no NEXTCLOUD_ADMIN_PASSWORD — generated one and persisted)"
  fi
  say "Installing Nextcloud headless (admin: $NC_ADMIN_USER)"
  occ maintenance:install \
    --database pgsql \
    --database-host nextcloud-db \
    --database-name nextcloud \
    --database-user nextcloud \
    --database-pass "$PG_NC_PW" \
    --admin-user "$NC_ADMIN_USER" \
    --admin-pass "$NC_ADMIN_PW" \
    --data-dir /var/www/html/data
  echo
  echo "  ############################################################"
  echo "  #  NEXTCLOUD ADMIN  (store off this box, then scrub)"
  echo "  #    URL:  https://$DOMAIN"
  echo "  #    user: $NC_ADMIN_USER"
  echo "  #    pass: $NC_ADMIN_PW"
  echo "  ############################################################"
fi

# =============================================================================
# 2. REVERSE-PROXY / URL SETTINGS  (supersedes nextcloud-proxy-fix.sh)
# =============================================================================
say "Reverse-proxy URL settings"
occ config:system:set overwriteprotocol --value=https
occ config:system:set overwritehost     --value="$DOMAIN"
occ config:system:set overwrite.cli.url --value="https://$DOMAIN"
occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"   # tighten to your proxy subnet for prod
occ config:system:set trusted_domains 1 --value="$DOMAIN"   # index 1: keep localhost at 0 for internal/CLI checks

# =============================================================================
# 3. LDAP  (captured from 0820 — group-gated, uid-pinned)
#    Load-bearing: capital `memberOf` (outpost is case-sensitive; lowercase GUI
#    filter matches nothing), uid pins (autodetect fails -> users skipped),
#    group gate to aftere-users (humans only), ldapEmailAttribute=mail (blank in
#    the GUI capture). ldapConfigurationActive is set LAST.
# =============================================================================
say "Configuring LDAP (user_ldap) against the Authentik outpost"
occ app:enable user_ldap >/dev/null 2>&1 || true

CID="$(occ ldap:show-config 2>/dev/null | grep -oE 's[0-9]{2}' | head -1 || true)"
if [[ -z "$CID" ]]; then
  CID="$(occ ldap:create-empty-config 2>&1 | grep -oE 's[0-9]{2}' | head -1 || true)"
fi
[[ -n "$CID" ]] || { echo "FATAL: couldn't determine an LDAP config id (is user_ldap enabled? is NC up?)"; exit 1; }
echo "  using LDAP config: $CID"

set_ldap() { occ ldap:set-config "$CID" "$1" "$2" >/dev/null; }

set_ldap ldapHost                 "authentik-ldap"
set_ldap ldapPort                 "3389"
set_ldap ldapTLS                  "0"
set_ldap ldapAgentName            "cn=aftere-ldap-bind,ou=users,dc=aftere,dc=internal"
set_ldap ldapAgentPassword        "$LDAP_BIND_PW"
set_ldap ldapBase                 "dc=aftere,dc=internal"
set_ldap ldapBaseUsers            "dc=aftere,dc=internal"
set_ldap ldapBaseGroups           "dc=aftere,dc=internal"
# filters (group-gated; capital memberOf)
set_ldap ldapUserFilter           "(&(objectclass=goauthentik.io/ldap/user)(memberOf=cn=aftere-users,ou=groups,dc=aftere,dc=internal))"
set_ldap ldapUserFilterObjectclass "goauthentik.io/ldap/user"
set_ldap ldapUserFilterGroups     "aftere-users"
set_ldap ldapLoginFilter          "(&(&(objectclass=goauthentik.io/ldap/user)(memberOf=cn=aftere-users,ou=groups,dc=aftere,dc=internal))(|(uid=%uid)(mailPrimaryAddress=%uid)(mail=%uid)(cn=%uid)))"
set_ldap ldapLoginFilterEmail     "1"
set_ldap ldapLoginFilterUsername  "1"
# attributes
set_ldap ldapEmailAttribute       "mail"
set_ldap ldapUserDisplayName      "displayName"
set_ldap ldapGroupDisplayName     "cn"
set_ldap ldapGidNumber            "gidnumber"
# the pins (never `auto`)
set_ldap ldapExpertUsernameAttr   "uid"
set_ldap ldapExpertUUIDUserAttr   "uid"
# housekeeping
set_ldap ldapCacheTTL             "600"
set_ldap ldapConnectionTimeout    "15"
set_ldap ldapPagingSize           "500"
set_ldap useMemberOfToDetectMembership "1"
# activate LAST
set_ldap ldapConfigurationActive  "1"

say "Testing the LDAP bind"
occ ldap:test-config "$CID" || echo "  (!) ldap:test-config failed — check the outpost is up + bind password"

# =============================================================================
# 4. APPS + SKELETON  (generic/maintained only — no Murena/ecloud apps)
# =============================================================================
say "Enabling apps"
for app in dashboard calendar contacts notes tasks quota_warning \
           bruteforcesettings suspicious_login twofactor_totp; do
  if occ app:enable "$app" >/dev/null 2>&1; then echo "  + $app"; else echo "  . $app (unavailable/appstore-needed — skipped)"; fi
done

say "Clearing the sample-file skeleton (new users start empty)"
occ config:system:set skeletondirectory --value '' >/dev/null
echo "  skeletondirectory emptied"

# =============================================================================
say "Done."
echo "  Verify:"
echo "    docker compose exec -T -u www-data nextcloud php occ user:list      # only humans + admin"
echo "    curl -sI https://$DOMAIN/remote.php/dav/                            # expect 401 (DAV alive)"
echo "  Users provision into NC on first login (phone or web)."
