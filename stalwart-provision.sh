#!/usr/bin/env bash
# =============================================================================
# after-e- — stalwart-provision.sh   (v0.16 / stalwart-cli 1.0.x)
# =============================================================================
# MODEL (corrected): on a FRESH data store, Stalwart self-initializes out of
# bootstrap mode on its own — no bootstrap object to apply, no restart. The
# server comes up blank-but-configured (no domain, empty hostname). Provisioning
# is then just normal object writes in ONE idempotent NDJSON plan:
#
#   Domain          -> the mail domain (matchOn name)
#   SystemSettings  -> defaultHostname = mail.<domain>, defaultDomainId -> #domain
#   Directory (Ldap)-> the LDAP directory (matchOn description)
#   Authentication  -> directoryId -> #aftere-ldap (make LDAP the auth directory)
#
# The #<key> forms are plan-local references resolved within the single apply.
# Plan values were captured from a PROVEN working state via `stalwart-cli
# snapshot` (not hand-written). apply is idempotent — re-running is safe.
# STALWART_RECOVERY_ADMIN (compose) is break-glass auth only.
# stalwart-cli is HOST-installed (prereqs.sh); TLS off (acme.sh owns certs).
#
# Prereq: ldap-bind.sh has run (LDAP_BIND_PASSWORD in .env).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root."
[[ ",$(getcfg COMPOSE_PROFILES)," == *",mail,"* ]] || { warn "mail profile not enabled — nothing to do."; exit 0; }
command -v stalwart-cli >/dev/null 2>&1 || die "stalwart-cli not found (run prereqs.sh)."
command -v envsubst    >/dev/null 2>&1 || die "envsubst not found (install gettext-base; prereqs.sh)."

CONFIG_PATH="$(getcfg AFTERE_CONFIG)"; DATA_PATH="$(getcfg AFTERE_DATA)"
AFTERE_DOMAIN="$(getcfg AFTERE_DOMAIN || true)"; [[ -n "$AFTERE_DOMAIN" ]] || die "no AFTERE_DOMAIN in .env/answers.env."
ADMIN_PW="$(getcfg STALWART_RECOVERY_PW || true)"; [[ -n "$ADMIN_PW" ]] || die "no STALWART_RECOVERY_PW in .env."
LDAP_BIND_PASSWORD="$(getcfg LDAP_BIND_PASSWORD || true)"
[[ -n "$LDAP_BIND_PASSWORD" ]] || die "no LDAP_BIND_PASSWORD in .env — run ldap-bind.sh first."

DIR_TMPL="${REPO_BASE}/stalwart-directory.json.tmpl"
[[ -f "$DIR_TMPL" ]] || die "missing $DIR_TMPL"

export STALWART_URL="http://localhost:8080"
export STALWART_USER="admin"
export STALWART_PASSWORD="$ADMIN_PW"
export AFTERE_DOMAIN LDAP_BIND_PASSWORD

# --- data-dir ownership: Stalwart runs as uid 2000 ---------------------------
step "Fixing Stalwart data-dir ownership"
chown -R 2000:2000 "${DATA_PATH}/stalwart" "${CONFIG_PATH}/stalwart" 2>/dev/null \
  && ok "chowned to uid 2000 (stalwart)" || warn "chown skipped/failed — verify Stalwart can write its store."

cd "$REPO_BASE"

# --- bring Stalwart up -------------------------------------------------------
step "Starting Stalwart"
docker compose up -d stalwart

# Honest readiness gate: poll the HOST management API (what stalwart-cli uses).
# %{http_code}==000 means no connection; anything else = reachable. On a fresh
# store the server self-initializes out of bootstrap during this window.
step "Waiting for the management API (host-reachable)"
deadline=$(( SECONDS + 120 ))
until code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "${STALWART_URL}/" 2>/dev/null) \
   && [[ "$code" != "000" ]]; do
  (( SECONDS > deadline )) && die "management API not reachable on the host at ${STALWART_URL} in 2 min — is 8080 published in compose? check: docker compose logs stalwart"
  sleep 4
done
ok "management API up (http $code)"

# Guard: confirm the server actually left bootstrap mode (fresh store does this
# itself). If it's still in bootstrap, object writes below would be forbidden.
step "Confirming Stalwart is configured (not in bootstrap mode)"
probe="$(stalwart-cli snapshot Directory --output /dev/null --allow-unresolved Tenant 2>&1 || true)"
if printf '%s' "$probe" | grep -qi 'bootstrap'; then
  die "Stalwart is still in bootstrap mode — a fresh store should self-initialize. Check: docker compose logs stalwart"
fi
ok "server configured"

# --- render + apply the single plan (idempotent) -----------------------------
step "Rendering directory/domain/auth plan"
RENDERED="${CONFIG_PATH}/stalwart/plan-directory.json"
mkdir -p "${CONFIG_PATH}/stalwart"
envsubst '${LDAP_BIND_PASSWORD} ${AFTERE_DOMAIN}' < "$DIR_TMPL" > "$RENDERED"
chmod 600 "$RENDERED"; ok "rendered -> $RENDERED"

step "Applying configuration via stalwart-cli"
stalwart-cli apply --file "$RENDERED" --dry-run >/dev/null \
  || die "plan failed --dry-run validation — inspect $RENDERED"
stalwart-cli apply --file "$RENDERED" \
  || die "apply failed — see output. Fix the plan and re-run (apply is idempotent)."
ok "domain, LDAP directory, and auth wiring applied"

# --- trust the internal proxy network (roundcube -> submission, etc.) ----------
# Stalwart treats AllowedIp addresses as local/trusted. The proxy subnet is pinned
# in docker-compose.yml (networks.proxy.ipam) — this MUST match it. Idempotent.
PROXY_SUBNET="172.20.0.0/16"
if stalwart-cli query AllowedIp 2>/dev/null | grep -q "$PROXY_SUBNET"; then
  ok "AllowedIp ${PROXY_SUBNET} already present"
else
  stalwart-cli create AllowedIp --field "address=${PROXY_SUBNET}" >/dev/null 2>&1 \
    && ok "trusted internal subnet ${PROXY_SUBNET} (AllowedIp)" \
    || warn "could not add AllowedIp ${PROXY_SUBNET} — internal submission may be rejected; add it manually."
fi

# --- SystemSettings: hostname + default domain (read-back, not #-ref) ---------
# defaultDomainId needs the Domain's REAL id; the plan-local "#key" ref does not
# resolve for this field (it silently no-ops). So read the id back from the live
# server after the Domain exists, then write SystemSettings with the literal id.
# Mirrors the ldap-bind.sh read-back pattern.
step "Setting server hostname + default domain (read-back)"
DID="$(stalwart-cli query Domain 2>/dev/null | awk -v d="$AFTERE_DOMAIN" 'NR>1 && $2==d {print $1; exit}')"
[[ -n "$DID" ]] || die "could not read back the Domain id for ${AFTERE_DOMAIN} (is the Domain upsert on the plan?)"
SS_PLAN="${CONFIG_PATH}/stalwart/plan-systemsettings.json"
printf '{"@type":"update","object":"SystemSettings","value":{"defaultHostname":"mail.%s","defaultDomainId":"%s"}}\n' \
  "$AFTERE_DOMAIN" "$DID" > "$SS_PLAN"
chmod 600 "$SS_PLAN"
stalwart-cli apply --file "$SS_PLAN" \
  || die "SystemSettings apply failed — see output."
# verify it actually took (this field has silently no-op'd before)
if ! stalwart-cli get SystemSettings 2>/dev/null | grep -q "mail.${AFTERE_DOMAIN}"; then
  die "SystemSettings did not persist defaultHostname — inspect: stalwart-cli get SystemSettings"
fi
ok "hostname=mail.${AFTERE_DOMAIN}, default domain=${AFTERE_DOMAIN} (id ${DID})"

# --- TLS certificate: point Stalwart at the acme.sh-issued cert ---------------
# Stalwart otherwise self-signs (CN=rcgen self signed cert), which mail clients —
# /e/OS especially — hard-refuse. A Certificate object with {"@type":"File",...}
# reads the mounted cert at load; cert-http.sh's mail reload-hook re-reads it on
# renewal. Proven on a live box (phone accepted the handshake). Idempotent: skip
# if a default cert is already set.
step "TLS certificate"
CERT_DIR="/etc/stalwart/certs/mail.${AFTERE_DOMAIN}"
if stalwart-cli get SystemSettings 2>/dev/null | grep -qiE 'defaultCertificateId.*[A-Za-z0-9]'; then
  ok "TLS certificate already configured"
elif [[ ! -f "${CONFIG_PATH}/certs/mail.${AFTERE_DOMAIN}/fullchain.pem" ]]; then
  warn "no cert at certs/mail.${AFTERE_DOMAIN}/ yet — run 'sudo STAGING=0 bash cert-http.sh' then re-run this script. Mail TLS will be self-signed until then."
else
  CERT_ID="$(stalwart-cli create Certificate \
      --field certificate="{\"@type\":\"File\",\"filePath\":\"${CERT_DIR}/fullchain.pem\"}" \
      --field privateKey="{\"@type\":\"File\",\"filePath\":\"${CERT_DIR}/privkey.pem\"}" 2>&1 \
      | grep -oE 'Created Certificate [A-Za-z0-9]+' | awk '{print $3}' || true)"
  if [[ -n "$CERT_ID" ]]; then
    printf '{"@type":"update","object":"SystemSettings","value":{"defaultCertificateId":"%s"}}\n' \
      "$CERT_ID" > "${CONFIG_PATH}/stalwart/plan-tlscert.json"
    stalwart-cli apply --file "${CONFIG_PATH}/stalwart/plan-tlscert.json" >/dev/null 2>&1 \
      && ok "TLS certificate configured (default: ${CERT_ID})" \
      || warn "created cert ${CERT_ID} but couldn't set it default — set defaultCertificateId on SystemSettings manually."
  else
    warn "couldn't create the TLS certificate object — mail TLS stays self-signed. Check: stalwart-cli create Certificate ..."
  fi
fi

# --- restart Stalwart so it loads the directory bind secret (qa_14) -----------
# Stalwart caches the directory's bind secret in memory; twice on fresh VMs the
# applied secret didn't take until a restart dropped the cache, so hal's login
# failed with "AUTHENTICATE PLAIN: Authentication failed" despite a correct .env.
# Doing the restart here removes the "operator must know to restart" failure.
step "Restarting Stalwart to load the directory secret"
if docker compose up -d --force-recreate stalwart >/dev/null 2>&1; then
  ok "stalwart recreated"
else
  warn "could not recreate stalwart — do it manually: docker compose up -d --force-recreate stalwart"
fi
step "Waiting for the management API after restart"
_deadline=$(( SECONDS + 120 ))
until _code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "${STALWART_URL}/" 2>/dev/null) \
   && [[ "$_code" != "000" ]]; do
  (( SECONDS > _deadline )) && { warn "management API not back after 2 min — check: docker compose logs stalwart"; break; }
  sleep 4
done
[[ "${_code:-000}" != "000" ]] && ok "management API back (http ${_code})"

# --- DKIM --------------------------------------------------------------------
step "DKIM"
warn "Domain uses Automatic DKIM — keys are generated server-side."
warn "Publish the public key as a DNS TXT record (read it from the Stalwart admin API/UI)."

# --- DNS zone (direct send only) ---------------------------------------------
# With a relay, SPF/DKIM point at the RELAY (relay-setup.sh covers that). For
# direct-to-MX send, the operator must publish this VM's own records — dump the
# zone file so they know exactly what to add. Non-fatal (field name may vary).
if [[ "$(getcfg MAIL_OUTBOUND_MODE 2>/dev/null)" != relay ]]; then
  step "DNS records to publish (direct send)"
  stalwart-cli get Domain "$DID" --fields dnsZoneFile \
    || warn "couldn't read the DNS zone from Stalwart — check the admin UI (Domains -> ${AFTERE_DOMAIN} -> DNS)."
fi

# =============================================================================
# Mail DNS verification   [build 20]
# =============================================================================
# Moved here from dns-setup.sh. These records decide whether mail FLOWS; they
# gate no certificate and no container start, so blocking a Nextcloud-only
# install on them was wrong. They run AFTER provisioning succeeded, so a failure
# here can't abort anything — it reports, offers a re-check, and lets the
# operator walk away with Ctrl+C. Nothing to unwind either way.
if command -v dig >/dev/null 2>&1; then
  step "Verifying mail DNS"
  _dom="$AFTERE_DOMAIN"
  _mode="$(getcfg MAIL_OUTBOUND_MODE 2>/dev/null || echo direct)"
  _ip="$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -n1 || true)"
  [[ -z "$_ip" ]] && _ip="$(curl -fsS -4 https://api.ipify.org 2>/dev/null || true)"

  while :; do
    _fails=0; _advisories=()

    # --- MX: blocking. No MX, no inbound mail, full stop.
    if dig +short MX "$_dom" | awk '{print $2}' | sed 's/\.$//' | grep -qx "mail.$_dom"; then
      ok "MX $_dom -> mail.$_dom"
    else
      bad "MX $_dom -> expected mail.$_dom, got '$(dig +short MX "$_dom" | paste -sd, -)'"
      _fails=$((_fails+1))
    fi

    # --- SPF: three tiers.
    # Absent is a hard fail (nothing valid looks like nothing). TWO OR MORE
    # records is also hard: RFC 7208 makes that a permerror, so every receiver
    # treats it as broken — it is the classic self-inflicted bug, from adding a
    # provider's record ALONGSIDE an existing one instead of merging them.
    # Anything present but unexpected is only a WARNING: relaying through SES,
    # Proxmox Mail Gateway, Xeams, a Sophos UTM or any other gateway is a
    # perfectly valid setup we have no business failing.
    mapfile -t _spf < <(dig +short TXT "$_dom" | tr -d '"' | grep -i '^v=spf1' || true)
    if (( ${#_spf[@]} == 0 )); then
      bad "no SPF record on $_dom — receivers will treat your mail as unauthenticated."
      _fails=$((_fails+1))
    elif (( ${#_spf[@]} > 1 )); then
      bad "${#_spf[@]} SPF records on $_dom — RFC 7208 makes multiple records a permanent"
      bad "error. Merge them into ONE record."
      _fails=$((_fails+1))
    else
      _want=""
      case "$_mode" in
        relay) case "$(getcfg RELAY_HOST 2>/dev/null || true)" in
                 *mailgun*) _want="include:mailgun.org" ;;
                 *smtp2go*) _want="include:spf.smtp2go.com" ;;
                 *mailjet*) _want="include:spf.mailjet.com" ;;
               esac ;;
        *)     [[ -n "$_ip" ]] && _want="ip4:${_ip}" ;;
      esac
      if [[ -z "$_want" || "${_spf[0]}" == *"$_want"* ]]; then
        ok "SPF present on $_dom"
      else
        warn "SPF on $_dom doesn't mention ${_want}."
        _advisories+=("SPF is '${_spf[0]}' — we expected it to include ${_want}. That is fine if you relay through SES, a mail gateway (Proxmox Mail Gateway, Xeams, Sophos UTM) or anything else we can't check; only you know your sending path. Note too that SPF PASSING and SPF ALIGNING with your domain are different things — some providers need a custom return-path CNAME for alignment.")
      fi
    fi

    # --- PTR: advisory, direct send only. With a relay, the relay's IP is what
    # receivers see, so your PTR is irrelevant.
    if [[ "$_mode" != relay && -n "$_ip" ]]; then
      _ptr="$(dig -x "$_ip" +short | sed 's/\.$//' || true)"
      if [[ "$_ptr" == "mail.$_dom" ]]; then
        ok "PTR $_ip -> mail.$_dom"
      else
        warn "PTR $_ip -> '${_ptr:-<none>}' (advisory)"
        _advisories+=("Reverse DNS for $_ip is '${_ptr:-<none>}', not mail.$_dom. Set it at your VM provider — the console that owns the IP, not your DNS registrar. It costs deliverability, not startup.")
      fi
    fi

    if (( _fails == 0 )); then
      if (( ${#_advisories[@]} )); then
        echo; printf '  %sAdvisory (not blocking):%s\n' "${c_warn:-}" "${c_end:-}"
        for _a in "${_advisories[@]}"; do echo "    - $_a"; done
      fi
      ok "mail DNS looks good"
      break
    fi
    echo
    printf '  %d mail DNS record(s) need attention. Mail will not flow correctly until they are fixed.\n' "$_fails"
    printf '  Records to create are listed by dns-setup.sh, and in %s/dns/zone.txt\n' "$(getcfg AFTERE_CONFIG 2>/dev/null || echo .)"
    read -r -p "  Press Enter to re-check (Ctrl+C to skip — Stalwart is already provisioned)... " _ < /dev/tty || break
  done
fi

step "Done"
printf '\n  %sOpen these inbound ports in your cloud firewall / NSG%s (mail clients + the\n' "${c_warn:-}" "${c_end:-}"
printf '  phone need them; a closed port here fails silently as "mail not working"):\n'
printf '    25    SMTP (inbound mail)         465 / 587  submission (sending)\n'
printf '    993   IMAPS (fetch)              4190  ManageSieve (filters)\n'
printf '\n  %s──── Stalwart break-glass admin (save OFF this box) ────%s\n' "${c_warn:-}" "${c_end:-}"
printf '    admin / %s   (management API: %s)\n' "$ADMIN_PW" "$STALWART_URL"
printf '  %s──── end ────%s\n' "${c_warn:-}" "${c_end:-}"
