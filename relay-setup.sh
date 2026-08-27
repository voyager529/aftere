#!/usr/bin/env bash
# =============================================================================
# after-e- — relay-setup.sh   (outbound mail via an authenticated SMTP relay)
# =============================================================================
# Owns the ENTIRE interactive relay flow; init.sh only records the decision in
# MAIL_OUTBOUND_MODE. Vendor-neutral — every provider is host / port / user /
# pass + a TLS mode. SMTP2GO's free tier is an easy default; Mailgun / Mailjet /
# Postmark / SES / Brevo / your-ISP all fit the same fields.
#
# Flow: prompt -> swaks AUTH preflight (proves creds/host/port/TLS; loops with a
# continue-anyway escape) -> apply the captured relay route + outbound strategy
# via stalwart-cli -> restart Stalwart -> postflight real send + queue poll.
#
# Templates were CAPTURED from a working v0.16 relay (aftere-0817, Mailgun 465),
# not hand-written — do not "clean up" their field shapes:
#   stalwart-relay.json.tmpl             -> MtaRoute (Relay), name "relay"
#   stalwart-outbound-strategy.json.tmpl -> MtaOutboundStrategy, route else->'relay'
#
# PORT/TLS PAIRING (this mismatch cost hours): 465 -> implicit TLS on connect;
# 587 or 2525 -> STARTTLS. A wrong pairing = silent TLS handshake failure = mail
# queues and retries forever with no useful error. It's derived from the port.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root."
[[ ",$(getcfg COMPOSE_PROFILES)," == *",mail,"* ]] || { warn "mail profile not enabled — nothing to do."; exit 0; }

MODE="$(getcfg MAIL_OUTBOUND_MODE 2>/dev/null || echo none)"
DOMAIN="$(getcfg AFTERE_DOMAIN || true)"

# --- direct mode = TRUE no-op ------------------------------------------------
# Stalwart's outbound strategy DEFAULTS to route.else -> 'mx' on a fresh box, so
# direct delivery needs ZERO config. Do NOT add an MX-strategy apply here — it's
# unnecessary and could conflict with the default. Direct = skip, literally.
if [[ "$MODE" == direct ]]; then
  step "Outbound mode: direct"
  ok "Direct send selected — Stalwart delivers via MX by default. Nothing to configure."
  echo "  (Direct-from-VM mail is very often spam-filtered. Switch to a relay any time by"
  echo "   re-running init.sh, choosing Relay, then re-running this script.)"
  exit 0
fi
if [[ "$MODE" != relay ]]; then
  warn "MAIL_OUTBOUND_MODE='$MODE' is neither 'relay' nor 'direct' — re-run init.sh. Nothing to do."
  exit 0
fi

command -v stalwart-cli >/dev/null 2>&1 || die "stalwart-cli not found (run prereqs.sh)."
command -v envsubst     >/dev/null 2>&1 || die "envsubst not found (prereqs.sh)."
command -v swaks        >/dev/null 2>&1 || die "swaks not found (it's in prereqs' base tools — run prereqs.sh)."

RELAY_TMPL="${REPO_BASE}/stalwart-relay.json.tmpl"
STRAT_TMPL="${REPO_BASE}/stalwart-outbound-strategy.json.tmpl"
[[ -f "$RELAY_TMPL" ]] || die "missing $RELAY_TMPL (the captured relay route template)."
[[ -f "$STRAT_TMPL" ]] || die "missing $STRAT_TMPL (the captured outbound-strategy template)."

ADMIN_PW="$(getcfg STALWART_RECOVERY_PW || true)"; [[ -n "$ADMIN_PW" ]] || die "no STALWART_RECOVERY_PW in .env."
CONFIG_PATH="$(getcfg AFTERE_CONFIG || echo /mnt/aftere/config)"

# prior values (if this is a re-run) pre-fill the prompts
RELAY_HOST="$(getcfg RELAY_HOST || true)"
RELAY_PORT="$(getcfg RELAY_PORT || true)"
RELAY_USER="$(getcfg RELAY_USER || true)"
RELAY_PASSWORD=""; RELAY_IMPLICIT_TLS=""; RELAY_ALLOW_INVALID_CERTS=""; SWAKS_TLS_FLAG=""

# --- derive TLS mode + swaks flag from the port ------------------------------
derive_tls() {
  case "$RELAY_PORT" in
    465)      RELAY_IMPLICIT_TLS=true;  SWAKS_TLS_FLAG="-tlsc" ;;   # implicit TLS on connect
    587|2525) RELAY_IMPLICIT_TLS=false; SWAKS_TLS_FLAG="-tls"  ;;   # STARTTLS
    *) warn "port $RELAY_PORT is non-standard (expected 465 implicit, or 587/2525 STARTTLS)."
       read -r -p "  Use implicit TLS (on-connect, 465-style)? [y/N]: " _t < /dev/tty
       if [[ "$_t" =~ ^[Yy] ]]; then RELAY_IMPLICIT_TLS=true; SWAKS_TLS_FLAG="-tlsc"
       else RELAY_IMPLICIT_TLS=false; SWAKS_TLS_FLAG="-tls"; fi ;;
  esac
}

prompt_relay() {
  step "Relay credentials"
  echo "  Vendor-neutral: host / port / username / password from your relay provider."
  echo "  Suggested: SMTP2GO (free tier). Mailgun / Mailjet / Postmark / SES all work too."
  local d
  d="${RELAY_HOST:-}";   read -r -p "  Relay host${d:+ [$d]}: " RELAY_HOST < /dev/tty;   RELAY_HOST="${RELAY_HOST:-$d}"
  [[ -n "$RELAY_HOST" ]] || { warn "host required."; return 1; }
  d="${RELAY_PORT:-465}"; read -r -p "  Relay port [$d] (465 implicit TLS / 587 STARTTLS): " RELAY_PORT < /dev/tty; RELAY_PORT="${RELAY_PORT:-$d}"
  [[ "$RELAY_PORT" =~ ^[0-9]+$ ]] || { warn "port must be a number."; return 1; }
  d="${RELAY_USER:-}";   read -r -p "  Relay username${d:+ [$d]}: " RELAY_USER < /dev/tty;   RELAY_USER="${RELAY_USER:-$d}"
  [[ -n "$RELAY_USER" ]] || { warn "username required."; return 1; }
  while :; do
    read -rs -p "  Relay password: " RELAY_PASSWORD < /dev/tty; echo
    [[ "$RELAY_PASSWORD" == *"'"* ]] && { warn "avoid the ' character (can't be stored safely in .env)."; continue; }
    [[ -n "$RELAY_PASSWORD" ]] && break || warn "password required."
  done
  read -r -p "  Does the relay use a self-signed / invalid cert? [y/N]: " _ic < /dev/tty
  [[ "$_ic" =~ ^[Yy] ]] && RELAY_ALLOW_INVALID_CERTS=true || RELAY_ALLOW_INVALID_CERTS=false
  derive_tls
  echo "  -> ${RELAY_HOST}:${RELAY_PORT}  implicitTls=${RELAY_IMPLICIT_TLS}  allowInvalidCerts=${RELAY_ALLOW_INVALID_CERTS}"
  return 0
}

# --- preflight: swaks AUTH-only, BEFORE touching Stalwart --------------------
preflight() {
  step "Preflight: testing relay auth with swaks (before touching Stalwart)"
  if swaks --server "$RELAY_HOST" --port "$RELAY_PORT" $SWAKS_TLS_FLAG \
       --auth --auth-user "$RELAY_USER" --auth-password "$RELAY_PASSWORD" \
       --quit-after AUTH >"/tmp/aftere-swaks.$$" 2>&1; then
    ok "relay accepted AUTH over TLS (${RELAY_HOST}:${RELAY_PORT})"
    rm -f "/tmp/aftere-swaks.$$"; return 0
  fi
  bad "relay did NOT accept the connection/auth. swaks said:"
  tail -n 15 "/tmp/aftere-swaks.$$" | sed 's/^/      /'
  rm -f "/tmp/aftere-swaks.$$"
  echo "  Common causes: wrong password; wrong port/TLS pairing (465 implicit vs 587 STARTTLS);"
  echo "  or the provider requires a verified sender/domain before it will accept mail."
  return 1
}

# gather + preflight loop (continue-anyway escape so the user is never trapped)
while :; do
  prompt_relay || continue
  if preflight; then break; fi
  read -r -p "  [R] re-enter details, or [c] continue anyway? [R/c]: " _c < /dev/tty
  if [[ "$_c" =~ ^[Cc] ]]; then warn "continuing despite a failed preflight — outbound may not work."; break; fi
done

# --- persist to .env (only now that we're committing) ------------------------
step "Saving relay settings to .env"
for k in RELAY_HOST RELAY_PORT RELAY_USER RELAY_PASSWORD RELAY_IMPLICIT_TLS RELAY_ALLOW_INVALID_CERTS; do
  sed -i "/^${k}=/d" "$ENV_FILE"
done
{
  printf "RELAY_HOST='%s'\n"                "$RELAY_HOST"
  printf "RELAY_PORT='%s'\n"                "$RELAY_PORT"
  printf "RELAY_USER='%s'\n"                "$RELAY_USER"
  printf "RELAY_PASSWORD='%s'\n"            "$RELAY_PASSWORD"
  printf "RELAY_IMPLICIT_TLS='%s'\n"        "$RELAY_IMPLICIT_TLS"
  printf "RELAY_ALLOW_INVALID_CERTS='%s'\n" "$RELAY_ALLOW_INVALID_CERTS"
} >> "$ENV_FILE"
ok "saved (RELAY_* live in .env; relay-setup owns them, not init)"

# --- inject: render + apply both captured templates --------------------------
export STALWART_URL="http://localhost:8080" STALWART_USER="admin" STALWART_PASSWORD="$ADMIN_PW"
export RELAY_HOST RELAY_PORT RELAY_USER RELAY_PASSWORD RELAY_IMPLICIT_TLS RELAY_ALLOW_INVALID_CERTS
cd "$REPO_BASE"
mkdir -p "${CONFIG_PATH}/stalwart"

apply_tmpl() {   # label  tmpl  envsubst-varlist
  local label="$1" tmpl="$2" vars="$3"
  local rendered="${CONFIG_PATH}/stalwart/plan-$(basename "$tmpl" .json.tmpl).json"
  envsubst "$vars" < "$tmpl" > "$rendered"; chmod 600 "$rendered"
  stalwart-cli apply --file "$rendered" --dry-run >/dev/null \
    || die "$label plan failed --dry-run validation — inspect $rendered"
  stalwart-cli apply --file "$rendered" \
    || die "$label apply failed — see output above."
  ok "$label applied"
}
step "Applying relay route + outbound strategy"
apply_tmpl "relay route" "$RELAY_TMPL" '${RELAY_HOST} ${RELAY_PORT} ${RELAY_USER} ${RELAY_PASSWORD} ${RELAY_IMPLICIT_TLS} ${RELAY_ALLOW_INVALID_CERTS}'
apply_tmpl "outbound strategy" "$STRAT_TMPL" '${__none__}'   # template has no vars; restrict to a no-op token

step "Restarting Stalwart to load the relay route"
docker compose up -d --force-recreate stalwart >/dev/null 2>&1 && ok "stalwart recreated" \
  || warn "could not recreate stalwart — do it manually: docker compose up -d --force-recreate stalwart"
_deadline=$(( SECONDS + 120 ))
until _code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "$STALWART_URL/" 2>/dev/null) && [[ "$_code" != "000" ]]; do
  (( SECONDS > _deadline )) && { warn "mgmt API not back after 2 min — check: docker compose logs stalwart"; break; }
  sleep 4
done

# --- postflight: real send THROUGH Stalwart, then poll the queue -------------
# warn-not-die from here: the relay is already applied, so a postflight hiccup
# must not unwind it — it's confirmation, not a gate.
step "Postflight: send a real message through Stalwart"
echo "  This proves Stalwart -> relay -> internet, not just the credentials. Use an EXTERNAL"
echo "  address (a murena.io address is a good on-brand pick). It must NOT be @${DOMAIN} — a"
echo "  same-domain address delivers locally and would false-pass."
read -r -p "  Test recipient (external), or blank to skip: " RCPT < /dev/tty
if [[ -z "$RCPT" ]]; then
  warn "postflight skipped — send a test from webmail, then: stalwart-cli query QueuedMessage"
elif [[ "$RCPT" == *"@${DOMAIN}" ]]; then
  warn "${RCPT} is @${DOMAIN} — delivers locally, won't exercise the relay. Skipping postflight."
else
  echo "  To submit through Stalwart I need a stack user that can authenticate (one you gave a"
  echo "  password via new-user.sh). Blank sender = skip the automated send."
  read -r -p "  Sender (user@${DOMAIN}), or blank to skip: " SENDER < /dev/tty
  if [[ -z "$SENDER" ]]; then
    warn "no sender — skipping automated send. Send from webmail and check: stalwart-cli query QueuedMessage"
  else
    read -rs -p "  Password for ${SENDER}: " SPASS < /dev/tty; echo
    step "Submitting a test via Stalwart submission (127.0.0.1:587 STARTTLS)"
    if swaks --server 127.0.0.1 --port 587 -tls --auth --auth-user "$SENDER" --auth-password "$SPASS" \
         --from "$SENDER" --to "$RCPT" \
         --header "Subject: after-e- relay test" --body "Relay test from after-e-." \
         >"/tmp/aftere-send.$$" 2>&1; then
      ok "Stalwart accepted the message for delivery"
    else
      warn "Stalwart did not accept the submission:"; tail -n 12 "/tmp/aftere-send.$$" | sed 's/^/      /'
    fi
    rm -f "/tmp/aftere-send.$$"; unset SPASS
    step "Watching the queue (up to ~30s)"
    _left=0
    for _i in $(seq 1 10); do
      _q="$(stalwart-cli query QueuedMessage 2>/dev/null || true)"
      printf '%s' "$_q" | grep -qi "$RCPT" || { _left=1; break; }
      sleep 3
    done
    if [[ "$_left" == 1 ]]; then
      ok "message left the queue — the relay accepted and forwarded it. That's a PASS."
      echo "  Scope: this confirms the relay accepts + forwards. Inbox vs spam placement is a"
      echo "  separate, reputation-based matter (SPF/DKIM/DMARC + sending history)."
    else
      warn "still queued after ~30s — likely stuck retrying (relay- or TLS-side, not creds)."
      echo "  Preflight already proved your credentials, so this is STALWART-SIDE. Check:"
      echo "    stalwart-cli query QueuedMessage      # the stuck message + retry count"
      echo "    docker compose logs stalwart          # the delivery error (needs the logging fix)"
      echo "    Stalwart admin :8080 -> MTA -> Outbound -> Routes  (verify the port/TLS pairing)"
    fi
  fi
fi

step "Done"
echo "  Relay route ${RELAY_HOST}:${RELAY_PORT} applied; Stalwart reloaded."
echo "  DNS: publish your relay's SENDING records (SPF include + DKIM) from the provider"
echo "  dashboard; keep your root MX on Stalwart (never the relay); start DMARC at p=none."
echo
echo "  Next: if you haven't yet, configure Nextcloud login:  sudo bash nextcloud-provision.sh"
