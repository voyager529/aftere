#!/usr/bin/env bash
# =============================================================================
# after-e- — cert-http.sh   (HTTP-01 via acme.sh)   [SECOND DRAFT]
# =============================================================================
# Separate cert per hostname in domains.list (seeded from the shared hostname
# model). Standalone challenge with nginx stopped + EXIT-trap restart. Installs
# each cert into certs/<host>/ with a reload hook; acme.sh's cron renews.
# STAGING default: Let's Encrypt staging (untrusted). STAGING=0 for real certs.
# =============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root (stops nginx, binds :80, writes certs)."

# STAGING: an explicit env value wins (so `STAGING=0 bash cert-http.sh` still
# forces production); otherwise honor the installer's saved choice; else default
# to staging. Lets a standalone run match what was picked in the questionnaire.
if [[ -z "${STAGING:-}" ]]; then
  [[ "$(getcfg AFTERE_CERT_STAGING 2>/dev/null || echo)" == Production* ]] && STAGING=0 || STAGING=1
fi
DOMAIN="$(getcfg AFTERE_DOMAIN || true)"; [[ -n "$DOMAIN" ]] || die "no AFTERE_DOMAIN (run init.sh first)."
CONFIG_PATH="$(getcfg AFTERE_CONFIG || echo /mnt/aftere/config)"
CERT_LOG="${CONFIG_PATH}/certificate-log.txt"
ADMIN_EMAIL="$(getcfg AFTERE_ADMIN_EMAIL || echo "postmaster@$DOMAIN")"
PROFILES="$(getcfg COMPOSE_PROFILES || true)"

ACME_HOME="${CONFIG_PATH}/acme"
CERTS_DIR="${CONFIG_PATH}/certs"
DOMAINS_FILE="${CERTS_DIR}/domains.list"
mkdir -p "$ACME_HOME" "$CERTS_DIR"

# --- ensure acme.sh (git-clone install; PIN a release tag at QA) ------------
if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
  step "Installing acme.sh into ${ACME_HOME}"
  command -v git   >/dev/null 2>&1 || die "git missing (run prereqs.sh)."
  command -v socat >/dev/null 2>&1 || die "socat missing (run prereqs.sh)."
  command -v crontab >/dev/null 2>&1 || die "cron/crontab missing (run prereqs.sh) — acme.sh needs it."
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp" || die "acme.sh clone failed."
  ( cd "$tmp" && ./acme.sh --install --home "$ACME_HOME" --accountemail "$ADMIN_EMAIL" >/dev/null ) \
    || die "acme.sh install failed."
  rm -rf "$tmp"
  ok "acme.sh installed (renewal cron registered)"
fi
ACME=( "${ACME_HOME}/acme.sh" --home "$ACME_HOME" )
"${ACME[@]}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

# --- seed / read domains.list (from the shared hostname model) --------------
if [[ ! -f "$DOMAINS_FILE" ]]; then
  step "Seeding ${DOMAINS_FILE}"
  { echo "# after-e- SSL domains — one hostname per line. Add + re-run to extend."
    active_hosts "$DOMAIN" "$PROFILES"; } > "$DOMAINS_FILE"
  ok "seeded $(grep -cvE '^\s*(#|$)' "$DOMAINS_FILE") hostnames"
fi
mapfile -t HOSTS < <(grep -vE '^\s*(#|$)' "$DOMAINS_FILE" | awk '{print $1}')
[[ ${#HOSTS[@]} -gt 0 ]] || die "no domains in ${DOMAINS_FILE}."

if [[ "$STAGING" == "1" ]]; then
  SERVER="letsencrypt_test"
  warn "${c_bold}STAGING${c_end} — untrusted test certs. Re-run with STAGING=0 for real ones."
else
  SERVER="letsencrypt"
  warn "${c_bold}PRODUCTION${c_end} certs (rate-limited; ensure staging passed first)."
fi
echo "  Issuing SEPARATE certs for:"; printf '    - %s\n' "${HOSTS[@]}"

# --- stop nginx; EXIT trap guarantees restart -------------------------------
cd "$REPO_BASE"
restore_nginx() { step "Restarting nginx"; docker compose start nginx >/dev/null 2>&1 && ok "nginx back up" || warn "restart nginx manually."; }
trap restore_nginx EXIT
step "Stopping nginx to free :80"
docker compose stop nginx >/dev/null 2>&1 || warn "nginx wasn't running (fine for first issue)."

# --- issue + install per host -----------------------------------------------
# acme.sh's full request/response chatter goes to CERT_LOG; the screen gets one
# tidy line per host. On failure we point at the log and the retry path.
printf '===== cert-http run %s (server=%s) =====\n' "$(date -Is 2>/dev/null || date)" "$SERVER" >> "$CERT_LOG" 2>/dev/null || true
step "Acquiring certificates (full detail in ${CERT_LOG})"
fails=0
for host in "${HOSTS[@]}"; do
  printf '  acquiring cert for %s... ' "$host"
  printf '\n----- %s : issue -----\n' "$host" >> "$CERT_LOG" 2>&1
  if "${ACME[@]}" --issue --standalone -d "$host" --server "$SERVER" >> "$CERT_LOG" 2>&1; then
    mkdir -p "${CERTS_DIR}/${host}"        # acme.sh won't create the target dir itself
    printf '\n----- %s : install -----\n' "$host" >> "$CERT_LOG" 2>&1
    # Per-host reload hook (runs on every acme.sh renewal). nginx always reloads;
    # the MAIL host additionally reloads Stalwart, which caches its cert in memory
    # and otherwise keeps presenting the stale (or self-signed) cert after renewal.
    # A restart re-reads the file-backed Certificate object (proven on the box).
    RELOAD="cd ${REPO_BASE} && docker compose exec -T nginx nginx -s reload 2>/dev/null || true"
    if [[ "$host" == "mail.${DOMAIN}" ]]; then
      RELOAD="${RELOAD}; docker compose restart stalwart 2>/dev/null || true"
    fi
    if "${ACME[@]}" --install-cert -d "$host" \
         --fullchain-file "${CERTS_DIR}/${host}/fullchain.pem" \
         --key-file       "${CERTS_DIR}/${host}/privkey.pem" \
         --reloadcmd      "$RELOAD" \
         >> "$CERT_LOG" 2>&1; then
      printf '%ssuccess%s\n' "$c_ok" "$c_end"
    else
      printf '%sfailed%s\n' "$c_err" "$c_end"
      warn "installed the cert for $host but the step reported a problem — see ${CERT_LOG}."
      fails=$((fails+1))
    fi
  else
    printf '%sfailed%s\n' "$c_err" "$c_end"
    warn "couldn't get a certificate for $host. Details are in the log at ${CERT_LOG}"
    warn "(usually a DNS record not pointing here yet). Fix it, re-run cert-http.sh, and the"
    warn "installer picks up the new cert automatically."
    fails=$((fails+1))
  fi
done

step "Done"
if (( fails )); then warn "$fails host(s) failed. Fix and re-run (valid certs are skipped)."; exit 1; fi
[[ "$STAGING" == "1" ]] && ok "Staging OK — re-run with STAGING=0 for real certs." \
                        || ok "Real certs in ${CERTS_DIR}/<host>/. acme.sh cron auto-renews."
