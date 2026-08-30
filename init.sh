#!/usr/bin/env bash
# =============================================================================
# after-e- — init.sh   (Phase 1)   [THIRD DRAFT]
# =============================================================================
# Bare host -> stack running over HTTPS. Input gathered up front (resumable
# answer file), secrets generated once, validated at load, fail-fast.
#
# New in draft 3: staging/production domain split + migration steer; user-chosen
# Authentik admin (seeded via bootstrap env against the fresh DB — no more
# akadmin password divergence); Immich privacy prompts; break-glass choice;
# fixed-max progress bar; Authentik blueprint render step; STALWART_RECOVERY_PW.
# Stalwart provisioning and postinstall are separate scripts init points to.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Collect warnings from this run (and the scripts it calls) into one roll-up the
# closer prints at the end, so a mostly-good run surfaces "here's what to look at"
# instead of the operator scrolling back through everything.
export AFTERE_WARN_LOG="$REPO_BASE/.aftere-run-warnings"
: > "$AFTERE_WARN_LOG" 2>/dev/null || true

[[ $EUID -eq 0 ]] || die "run as root."
command -v docker >/dev/null 2>&1 || die "docker not found (run prereqs.sh)."
docker compose version >/dev/null 2>&1 || die "compose plugin missing (run prereqs.sh)."
command -v envsubst >/dev/null 2>&1 || die "envsubst missing (run prereqs.sh)."

# =============================================================================
# resume gate — a prior run left answers behind
# =============================================================================
# Checked BEFORE we touch the answer file (so "before" means genuinely before).
if [[ -s "$ANSWER_FILE" ]]; then
  echo
  echo "  Looks like setup has run here before — your previous answers are saved. That"
  echo "  usually means an earlier run stopped partway through."
  echo "    1) Pick up where I left off"
  echo "    2) Start over (delete saved answers)"
  read -r -p "  choice [1-2]: " _resume < /dev/tty
  if [[ "$_resume" == 2 ]]; then
    # "Start over" is clean ONLY before anything is deployed. Once a .env is
    # rendered or containers are up, the generated secrets are already baked into
    # a running Authentik — deleting answers and regenerating would silently
    # diverge from what's deployed. Steer to reset.sh for a true clean slate.
    deployed=no
    [[ -f "$ENV_FILE" ]] && deployed=yes
    [[ "$deployed" == no ]] && [[ -n "$(cd "$REPO_BASE" && docker compose ps -q 2>/dev/null)" ]] && deployed=yes
    [[ "$deployed" == yes ]] && die "this stack looks partly deployed (a .env or running containers exist) — 'start over' would wipe deployed state, not just answers. For a clean slate run: sudo bash reset.sh"
    rm -f "$ANSWER_FILE"
    ok "cleared saved answers — starting fresh."
  else
    ok "picking up where you left off."
  fi
fi

touch "$ANSWER_FILE"; chmod 600 "$ANSWER_FILE"

# =============================================================================
# questionnaire engine + fixed-max progress bar
# =============================================================================
# Every question site does QN=$((QN+1)) whether asked or skipped, so QN always
# ends at QMAX on every path (the bar always reaches 100%). The bar is drawn
# only when a question is actually prompted (skipped/cached ones tick silently).
QN=0
QMAX=17          # number of question sites below — keep in sync (asserted at end)

draw_bar() {
  # if a question pre-drew the bar (so its description sits below the bar),
  # skip this call and clear the flag.
  if [[ "${_bar_predrawn:-0}" == 1 ]]; then _bar_predrawn=0; return; fi
  local w=28 f e
  f=$(( QN * w / QMAX ))
  (( f > w )) && f=$w
  e=$(( w - f ))
  printf '\n  [%s%s]  question %d of %d\n\n' \
    "$(printf '%*s' "$f" '' | tr ' ' '=')" "$(printf '%*s' "$e" '' | tr ' ' '.')" "$QN" "$QMAX"
}
# draw the bar NOW, for a question whose description block should appear BELOW
# the bar. QN is already incremented at the call site. Suppresses the following
# ask/ask_choice's own draw_bar so the bar isn't drawn twice.
predraw() { draw_bar; _bar_predrawn=1; }

answer_get() { sed -n "s/^$1=//p" "$ANSWER_FILE" | head -n1; }
answer_set() { local k="$1"; shift; sed -i "/^${k}=/d" "$ANSWER_FILE"; printf '%s=%s\n' "$k" "$*" >> "$ANSWER_FILE"; }

ask() {   # key prompt [regex] [hint]
  local key="$1" prompt="$2" re="${3:-.}" hint="${4:-invalid, try again}" cur input=""
  cur="$(answer_get "$key")"
  if [[ -n "$cur" ]]; then [[ "$cur" =~ $re ]] || die "cached $key='$cur' invalid ($hint). Edit ${ANSWER_FILE} or rm it."; _bar_predrawn=0; return; fi
  draw_bar
  while :; do read -r -p "  $prompt: " input < /dev/tty; [[ "$input" =~ $re ]] && break
    printf '    %s%s%s\n' "$c_warn" "$hint" "$c_end"; done
  answer_set "$key" "$input"
}
ask_choice() {   # key prompt opt...
  local key="$1" prompt="$2"; shift 2; local opts=("$@") cur n
  cur="$(answer_get "$key")"
  if [[ -n "$cur" ]]; then printf '%s\n' "${opts[@]}" | grep -qxF "$cur" || die "cached $key='$cur' invalid. Edit ${ANSWER_FILE}."; _bar_predrawn=0; return; fi
  draw_bar
  printf '  %s\n' "$prompt"; local i=1; for o in "${opts[@]}"; do printf '    %d) %s\n' "$i" "$o"; i=$((i+1)); done
  while :; do read -r -p "  choice [1-${#opts[@]}]: " n < /dev/tty
    [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#opts[@]} )) && break
    printf '    %spick 1-%d%s\n' "$c_warn" "${#opts[@]}" "$c_end"; done
  answer_set "$key" "${opts[$((n-1))]}"
}
# like ask_choice but for a two-way choice where we want friendlier labels on
# screen while storing a canonical yes/no downstream. yes_label is option 1.
ask_yesno() {   # key prompt yes_label no_label
  local key="$1" prompt="$2" yl="$3" nl="$4" cur n
  cur="$(answer_get "$key")"
  if [[ -n "$cur" ]]; then
    [[ "$cur" == yes || "$cur" == no ]] || die "cached $key='$cur' invalid (want yes/no). Edit ${ANSWER_FILE}."
    _bar_predrawn=0; return
  fi
  draw_bar
  printf '  %s\n' "$prompt"
  printf '    1) %s\n' "$yl"
  printf '    2) %s\n' "$nl"
  while :; do read -r -p "  choice [1-2]: " n < /dev/tty
    [[ "$n" == 1 || "$n" == 2 ]] && break
    printf '    %spick 1 or 2%s\n' "$c_warn" "$c_end"; done
  answer_set "$key" "$([[ "$n" == 1 ]] && echo yes || echo no)"
}
ask_secret() {   # key prompt minlen
  local key="$1" prompt="$2" min="${3:-12}" p1 p2
  [[ -n "$(answer_get "$key")" ]] && return
  draw_bar
  while :; do
    read -rs -p "  $prompt (min ${min} chars): " p1 < /dev/tty; echo
    [[ ${#p1} -ge $min ]] || { printf '    %stoo short%s\n' "$c_warn" "$c_end"; continue; }
    read -rs -p "  confirm: " p2 < /dev/tty; echo
    [[ "$p1" == "$p2" ]] && break || printf '    %smismatch%s\n' "$c_warn" "$c_end"
  done
  answer_set "$key" "$p1"; unset p1 p2
}
gen_secret() {
  local key="$1" len="$2" class="${3:-mixed}" charset
  [[ -n "$(answer_get "$key")" ]] && return
  case "$class" in lower) charset='a-z0-9';; upper) charset='A-Z0-9';; *) charset='a-zA-Z0-9';; esac
  answer_set "$key" "$(tr -dc "$charset" </dev/urandom | head -c "$len")"
}

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
PATH_RE='^/.+'

step "Questionnaire"

# 1 — production domain (the ultimate identity)
QN=$((QN+1)); ask AFTERE_PRODUCTION_DOMAIN "Production domain — the identity users will ultimately have (e.g. example.com)" "$DOMAIN_RE" "not a valid domain"

# 2 — migration / staging
QN=$((QN+1)); ask_choice AFTERE_MIGRATION_CHOICE \
  "Is this domain live elsewhere (an existing server you'll migrate from), or fresh?" \
  "Fresh — use this domain directly" \
  "Live elsewhere — I'll build on a STAGING domain now and cut over later"

# 3 — staging domain value (only if migrating)
QN=$((QN+1))
if [[ "$(answer_get AFTERE_MIGRATION_CHOICE)" == Live* ]]; then
  answer_set AFTERE_MIGRATION yes
  ask AFTERE_STAGING_DOMAIN "Staging domain to build on now (NOT your production domain)" "$DOMAIN_RE" "not a valid domain"
else
  answer_set AFTERE_MIGRATION no
fi

PROD_DOMAIN="$(answer_get AFTERE_PRODUCTION_DOMAIN)"
STAGING_DOMAIN="$(answer_get AFTERE_STAGING_DOMAIN || true)"
DOMAIN="${STAGING_DOMAIN:-$PROD_DOMAIN}"     # the domain the box SERVES right now
answer_set AFTERE_DOMAIN "$DOMAIN"

if [[ "$(answer_get AFTERE_MIGRATION)" == yes ]]; then
  warn "Building on ${c_bold}${STAGING_DOMAIN}${c_end}. Your production domain ${c_bold}${PROD_DOMAIN}${c_end} stays"
  warn "live on its current server — do NOT point it here until you've migrated + verified."
  warn "When ready: migrate with migration.sh, then cut over with change-domain.sh."
fi

# 4 — admin email (becomes akadmin's email attribute; akadmin's PASSWORD is
#     generated, not typed — typed secrets get mangled by compose interpolation)
QN=$((QN+1)); ask AFTERE_ADMIN_EMAIL "Admin email (akadmin's email; you can also log in with it)" "$EMAIL_RE" "not a valid email"

# 5 — install paths
QN=$((QN+1))
if [[ -z "$(answer_get AFTERE_CONFIG)" ]]; then
  predraw
  echo "  Defaults: config -> /mnt/aftere/config, bulk data -> /mnt/aftere/data"
  ask_choice AFTERE_PATHCHOICE "Change either install path?" "keep defaults" "change data path" "change config path" "change both"
else
  : # cached; still tick
fi
case "$(answer_get AFTERE_PATHCHOICE)" in
  "keep defaults")      answer_set AFTERE_CONFIG /mnt/aftere/config; answer_set AFTERE_DATA /mnt/aftere/data ;;
  "change data path")   answer_set AFTERE_CONFIG /mnt/aftere/config ;;
  "change config path") answer_set AFTERE_DATA   /mnt/aftere/data ;;
esac
# 7 — config path (conditional)
QN=$((QN+1))
[[ "$(answer_get AFTERE_PATHCHOICE)" == "change config path" || "$(answer_get AFTERE_PATHCHOICE)" == "change both" ]] && \
  ask AFTERE_CONFIG "Config path" "$PATH_RE" "absolute path"
# 8 — data path (conditional)
QN=$((QN+1))
[[ "$(answer_get AFTERE_PATHCHOICE)" == "change data path" || "$(answer_get AFTERE_PATHCHOICE)" == "change both" ]] && \
  ask AFTERE_DATA "Data path" "$PATH_RE" "absolute path"

CONFIG_PATH="$(answer_get AFTERE_CONFIG)"; DATA_PATH="$(answer_get AFTERE_DATA)"
if [[ "$DATA_PATH" != /mnt/aftere/data ]] && command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$DATA_PATH" 2>/dev/null; then
  warn "$DATA_PATH is not a mountpoint — if it's a separate volume, mount it (+fstab) first."
fi

# 9 — tier
QN=$((QN+1)); predraw
echo "  All tiers include Nginx, Authentik, CrowdSec, and Nextcloud. Tiers add:"
echo "    Kitchen Sink                (+ Mail [Stalwart + Roundcube], Photos [Immich], Vaultwarden)"
echo "    /e/Cloud Server Replacement (+ Mail [Stalwart + Roundcube]; photos live in Nextcloud)"
echo "    Everything but Mail         (+ Photos [Immich], Vaultwarden)"
echo "    File Sync Only              (just the always-on core — files, calendar, contacts)"
ask_choice AFTERE_TIER "Which tier?" "Kitchen Sink" "/e/Cloud Server Replacement" "Everything but Mail" "File Sync Only"
case "$(answer_get AFTERE_TIER)" in
  "Kitchen Sink")                PROFILES="mail,photos,vault" ;;
  "/e/Cloud Server Replacement") PROFILES="mail" ;;
  "Everything but Mail")         PROFILES="photos,vault" ;;
  "File Sync Only")              PROFILES="" ;;
esac
# The /e/Cloud server ships no password manager. Offer Vaultwarden as an explicit
# opt-in for this tier only; parity (no vault) is the "No" option.
if [[ "$(answer_get AFTERE_TIER)" == "/e/Cloud Server Replacement" ]]; then
  predraw
  echo "  The /e/Cloud server has no built-in password manager. after-e- can add"
  echo "  Vaultwarden (Bitwarden-compatible) if you want one."
  ask_yesno AFTERE_ADD_VAULT "Add Vaultwarden for password management?" \
    "Yes — add Vaultwarden" \
    "No — keep parity with the /e/Cloud server"
  [[ "$(answer_get AFTERE_ADD_VAULT)" == yes ]] && PROFILES="${PROFILES:+$PROFILES,}vault"
fi
answer_set COMPOSE_PROFILES "$PROFILES"

# --- port 25 conflict check (mail tier only) --------------------------------
# A local MTA (exim4/postfix) on :25 blocks Stalwart from binding and aborts the
# bring-up. We measure success by RE-PROBING the port, not by trusting an exit
# code — exim4's SysV-wrapped unit can report non-zero even when the stop worked
# (and vice-versa). Two tiers: stop+disable first, escalate to a scoped purge
# only if the port is still held.
check_port25() {
  ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE '(^|[:.])25$'
}
port25_owner() {
  ss -tlnp 2>/dev/null | awk '$4 ~ /(^|[:.])25$/' | grep -oE 'users:\(\("[^"]+' | grep -oE '[^"]+$' | head -n1
}
# map the listening process name to the unit/package family that owns it.
# postfix's listener shows up as "master"; exim as "exim4".
port25_unit() {
  case "$1" in
    master|qmgr|pickup|postfix*) echo postfix ;;
    exim*)                       echo exim4 ;;
    *)                           echo "" ;;
  esac
}
# give the socket a moment to actually release, then report whether it's free.
port25_free() { local t=0; while (( t<8 )); do check_port25 || return 0; sleep 1; t=$((t+1)); done; check_port25 && return 1 || return 0; }

if [[ ",$PROFILES," == *",mail,"* ]] && check_port25; then
  owner="$(port25_owner || true)"; unit="$(port25_unit "$owner")"
  warn "Something is already listening on port 25 (${owner:-unknown}). Stalwart needs it."
  if [[ -z "$unit" ]]; then
    echo "  I don't recognize that service, so I won't touch it automatically. Free port 25"
    echo "  yourself (find it with:  ss -tlnp | grep ':25'  ), then re-run."
    die "port 25 is in use by an unrecognized service — resolve it and re-run."
  fi
  echo "  That's ${unit}. Stalwart can't start until port 25 is free."
  echo "    1) Stop and disable ${unit} now"
  echo "    2) Stop here — I'll handle it myself"
  read -r -p "  choice [1-2]: " _p25 < /dev/tty
  [[ "$_p25" == 1 ]] || die "resolve the :25 conflict (e.g. systemctl disable --now ${unit}) and re-run."

  # tier 1 — stop + disable, then measure by re-probing the port.
  systemctl stop "$unit"    >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
  if port25_free; then
    answer_set AFTERE_P25_AUTOSTOP "$unit"
    ok "port 25 is free (${unit} stopped and disabled)."
  else
    # tier 2 — a stop didn't clear it; offer the more thorough purge.
    warn "Stopping ${unit} didn't free port 25 — a normal stop doesn't always clear it."
    echo "  The reliable fix is to remove it completely (you won't need it once Stalwart's"
    echo "  running):"
    if [[ "$unit" == exim4 ]]; then
      mapfile -t _pkgs < <(dpkg-query -W -f='${Package}\n' 'exim4*' 2>/dev/null | grep . || true)
      (( ${#_pkgs[@]} == 0 )) && _pkgs=(exim4 exim4-base exim4-config exim4-daemon-light)
    else
      mapfile -t _pkgs < <(dpkg-query -W -f='${Package}\n' 'postfix*' 2>/dev/null | grep . || true)
      (( ${#_pkgs[@]} == 0 )) && _pkgs=(postfix)
    fi
    echo "      apt-get purge -y ${_pkgs[*]}"
    echo "      apt-get autoremove -y"
    echo "    1) Remove it now"
    echo "    2) Stop here — I'll handle it myself"
    read -r -p "  choice [1-2]: " _p25b < /dev/tty
    if [[ "$_p25b" == 1 ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_pkgs[@]}" >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y      >/dev/null 2>&1 || true
      if port25_free; then
        answer_set AFTERE_P25_AUTOSTOP "$unit"
        ok "port 25 is free (${unit} removed)."
      else
        bad "port 25 is STILL in use after removing ${unit}."
        echo "  Something unexpected is holding it. Inspect and clear it by hand:"
        echo "      ss -tlnp | grep ':25'"
        die "couldn't free port 25 automatically — see above and re-run."
      fi
    else
      die "resolve the :25 conflict and re-run (purge shown above, or your own method)."
    fi
  fi
fi

# 10 — Immich ML  (stored yes/no; drives the immich-ml compose profile)
QN=$((QN+1))
if [[ ",$PROFILES," == *",photos,"* ]]; then
  predraw
  echo "  Immich can recognize faces and let you search photos by what's in them"
  echo "  (\"beach\", \"the dog\"). Nice to have, but it wants an extra 1–2 GB of RAM and"
  echo "  leans on your CPU — fair to skip on a smaller box."
  ask_yesno AFTERE_IMMICH_ML "Turn on machine learning?" \
    "Yes — face recognition + smart search" \
    "No — keep it lightweight"
  if [[ "$(answer_get AFTERE_IMMICH_ML)" == yes ]]; then
    # the ML container lives in its own compose profile; add it so it starts.
    PROFILES="${PROFILES:+$PROFILES,}immich-ml"
    answer_set COMPOSE_PROFILES "$PROFILES"
  fi
else answer_set AFTERE_IMMICH_ML no; fi

# 11 — Immich map reverse-geocoding (privacy)
QN=$((QN+1))
if [[ ",$PROFILES," == *",photos,"* ]]; then
  predraw
  echo "  Immich can turn the GPS in your photos into place names — \"Montauk, NY\" instead"
  echo "  of a pair of numbers. It's all local, from a built-in database; nothing leaves"
  echo "  your server."
  ask_yesno AFTERE_IMMICH_MAP "Name the places your photos were taken?" \
    "Yes — name the places my photos were taken" \
    "No — leave coordinates as-is"
else answer_set AFTERE_IMMICH_MAP no; fi

# 12 — Immich release check (privacy)
QN=$((QN+1))
if [[ ",$PROFILES," == *",photos,"* ]]; then
  predraw
  echo "  Immich can check for new versions now and then. It only checks — it never"
  echo "  downloads or installs anything (that's update.sh's job). Off is a little more"
  echo "  private; all it changes is whether the web interface nudges you."
  ask_yesno AFTERE_IMMICH_RELEASECHECK "Let Immich check for new versions?" \
    "Yes — check for new versions" \
    "No — don't phone home (recommended)"
else answer_set AFTERE_IMMICH_RELEASECHECK no; fi

# 13 — outbound mail mode. Relay recommended; CREDENTIALS + validation now live
# in relay-setup.sh (run later), so init records only the DECISION here — no SMTP
# fields. (-4 question sites vs qa_14: host/port/user/pass moved to relay-setup.)
QN=$((QN+1))
if [[ ",$PROFILES," == *",mail,"* ]]; then
  if [[ -z "$(answer_get MAIL_OUTBOUND_MODE_CHOICE)" ]]; then
    predraw
    echo "  Outbound email: Many cloud providers (AWS, Azure, Digital Ocean, Linode,"
    echo "  and others) have their entire IP ranges blocked by most mail filters. Many"
    echo "  of them also block sending mail by default. Residential ISPs are usually 
    echo "  subject to both limits. Hetzner and OVA are" better choices if you'd like to"
    echo "  send mail directly, but an alternative solution is to use a relay service like"
    echo "  Mailgun, SMTP2Go, Resend, or Mailjet. These services reduce privacy because all"
    echo "  your sent mail flows through them, but the tradeoff is that your email will be"
    echo "  more likely to successfully reach your recipients, and all have free tiers if"
    echo "  you send less than 1,000 emails a month from your server."
  fi
  ask_choice MAIL_OUTBOUND_MODE_CHOICE "Use a relay, or send directly from the server?" \
    "Relay (recommended)" "Direct send"
  case "$(answer_get MAIL_OUTBOUND_MODE_CHOICE)" in
    "Relay (recommended)") answer_set MAIL_OUTBOUND_MODE relay ;;
    "Direct send")         answer_set MAIL_OUTBOUND_MODE direct ;;
  esac
else answer_set MAIL_OUTBOUND_MODE none; fi
MAILMODE="$(answer_get MAIL_OUTBOUND_MODE)"

# 18 — cert mode
QN=$((QN+1)); ask_choice AFTERE_CERT_CHOICE "Certificate acquisition?" \
  "HTTP-01 (port 80 open, all hostnames resolve)" "Cloudflare DNS-01 (wildcard; scoped token)" "Bring your own certs"
case "$(answer_get AFTERE_CERT_CHOICE)" in
  "Cloudflare DNS-01 (wildcard; scoped token)") answer_set CERT_MODE cloudflare ;;
  "Bring your own certs")                        answer_set CERT_MODE byo ;;
  *)                                             answer_set CERT_MODE http01 ;;
esac

# 18b — staging vs production certificates (only meaningful when ACME issues them)
QN=$((QN+1))
if [[ "$(answer_get CERT_MODE)" != byo ]]; then
  predraw
  echo "  Two kinds of certificate. Staging certs are unlimited but make browsers warn —"
  echo "  good for a first run while you sort out DNS. Production certs are real and trusted,"
  echo "  but Let's Encrypt rate-limits them per week, so switch over once a staging run goes"
  echo "  cleanly end to end."
  ask_choice AFTERE_CERT_STAGING "Which certificates for this run?" \
    "Staging — test certs (browser will warn; good for first runs)" \
    "Production — real trusted certs (use once staging looks good)"
else
  # bring-your-own: nothing is issued, so this choice is moot — record a value so
  # the progress counter and any read-back stay consistent.
  answer_set AFTERE_CERT_STAGING "Staging — test certs (browser will warn; good for first runs)"
fi

# 19 — break-glass admin accounts
QN=$((QN+1)); ask_choice AFTERE_BREAKGLASS \
  "Create per-app break-glass admin accounts (emergency access if Authentik is down)?" \
  "Yes — also create local emergency admins" \
  "No — my Authentik login is the only admin"
if [[ "$(answer_get AFTERE_BREAKGLASS)" == No* ]]; then
  warn "No break-glass: if Authentik ever fails to start (bad upgrade, corrupt DB, expired"
  warn "auth cert) you'll be locked out of EVERY app at once — including the tools to fix it."
  warn "Recovery would mean command-line database surgery. (Re-run to change your mind.)"
else
  warn "Break-glass accounts bypass Authentik entirely — and thus its MFA/session control."
  warn "They're emergency-only; postinstall will show them fenced — store them OFF this box."
fi

# 20 — Dockhand (optional Docker management UI)
QN=$((QN+1)); predraw
echo "  after-e- is a dozen-odd containers. Dockhand is a web UI for managing them"
echo "  — start/stop, logs, redeploy — without living in the shell."
echo
echo "  It needs the Docker socket, which makes it root-equivalent on this box, and"
echo "  it can read this stack's .env. It is published on localhost only either way."
ask_yesno AFTERE_DOCKHAND "Install Dockhand for Docker management?" \
  "Yes — install the management UI" \
  "No — I'll use the docker CLI"
if [[ "$(answer_get AFTERE_DOCKHAND)" == yes ]]; then
  PROFILES="${PROFILES:+$PROFILES,}dockhand"
  answer_set COMPOSE_PROFILES "$PROFILES"
fi

# 21 — how Dockhand is reached (only meaningful if it's installed)
QN=$((QN+1))
if [[ "$(answer_get AFTERE_DOCKHAND)" == yes ]]; then
  predraw
  echo "  How do you want to reach it?"
  echo
  echo "    A vhost gives it HTTPS and puts its requests in nginx's logs, which is"
  echo "    what CrowdSec watches — but it needs one more DNS record before certs"
  echo "    are issued (dockhand.$DOMAIN, a CNAME to $DOMAIN)."
  echo
  echo "    A tunnel needs no DNS and no open port: ssh -L 3000:127.0.0.1:3000"
  echo "    to this box, then browse http://localhost:3000."
  ask_yesno AFTERE_DOCKHAND_VHOST "Publish Dockhand at a hostname?" \
    "Yes — serve it at https://dockhand.$DOMAIN" \
    "No — I'll reach it over an SSH tunnel"
  if [[ "$(answer_get AFTERE_DOCKHAND_VHOST)" == yes ]]; then
    # marker profile: carries the choice into active_hosts() so the DNS gate and
    # cert-http's SAN list both pick the hostname up. Declares no service.
    PROFILES="${PROFILES:+$PROFILES,}dockhand-vhost"
    answer_set COMPOSE_PROFILES "$PROFILES"
  fi
else
  answer_set AFTERE_DOCKHAND_VHOST no
fi

# progress sanity (dev): QN must equal QMAX on every path
(( QN == QMAX )) || warn "progress counter drift: ended at $QN/$QMAX (harmless; fix QMAX)."

# =============================================================================
# secrets (generate once)  —  AUTHENTIK_BOOTSTRAP_PASSWORD is generated
# (alphanumeric) so compose's .env interpolation can't mangle it
# =============================================================================
step "Generating secrets (once; cached for resume)"
# --- secret freeze --------------------------------------------------------
# Generated secrets are sacrosanct once a .env exists: they're already baked into
# running containers (Authentik's DB, etc.), so regenerating them on a re-run
# would silently diverge from what's deployed — a worse-than-first-attempt state.
# answers.env is deleted on a successful run, so on a re-run gen_secret's "skip if
# already set" has nothing to protect. Hydrate the existing .env secret values
# back into answers FIRST so that skip logic preserves them. reset.sh remains the
# ONLY way to rotate secrets. (AUTHENTIK_LDAP_TOKEN / LDAP_BIND_PASSWORD carry
# real server-issued values written by ldap-token/ldap-bind — freezing keeps
# those, not stale placeholders.)
if [[ -f "$ENV_FILE" ]]; then
  _frozen=0
  for _k in PG_AUTHENTIK_PASSWORD PG_NEXTCLOUD_PASSWORD PG_IMMICH_PASSWORD \
            AUTHENTIK_SECRET_KEY AUTHENTIK_BOOTSTRAP_PASSWORD AUTHENTIK_BOOTSTRAP_TOKEN \
            AUTHENTIK_LDAP_TOKEN VAULTWARDEN_ADMIN_TOKEN \
            OIDC_NEXTCLOUD_SECRET OIDC_IMMICH_SECRET OIDC_VAULTWARDEN_SECRET OIDC_ROUNDCUBE_SECRET NEXTCLOUD_ADMIN_PASSWORD \
            LDAP_BIND_PASSWORD STALWART_RECOVERY_PW DOCKHAND_ADMIN_PASSWORD; do
    _v="$(getcfg "$_k" 2>/dev/null || true)"
    if [[ -n "$_v" && -z "$(answer_get "$_k")" ]]; then answer_set "$_k" "$_v"; _frozen=$((_frozen+1)); fi
  done
  (( _frozen > 0 )) && ok "preserved ${_frozen} existing secrets from .env (run reset.sh to rotate)"
fi
gen_secret PG_AUTHENTIK_PASSWORD 40 lower; gen_secret PG_NEXTCLOUD_PASSWORD 40 lower; gen_secret PG_IMMICH_PASSWORD 40 lower
gen_secret AUTHENTIK_SECRET_KEY 60; gen_secret AUTHENTIK_BOOTSTRAP_PASSWORD 24; gen_secret AUTHENTIK_BOOTSTRAP_TOKEN 40 lower; gen_secret AUTHENTIK_LDAP_TOKEN 40 lower
gen_secret VAULTWARDEN_ADMIN_TOKEN 40
gen_secret OIDC_NEXTCLOUD_SECRET 50; gen_secret OIDC_IMMICH_SECRET 50; gen_secret OIDC_VAULTWARDEN_SECRET 50
gen_secret LDAP_BIND_PASSWORD 40
gen_secret NEXTCLOUD_ADMIN_PASSWORD 24; gen_secret OIDC_ROUNDCUBE_SECRET 50
gen_secret STALWART_RECOVERY_PW 24
# alphanumeric by default, which also keeps it JSON-safe for the bootstrap POST
gen_secret DOCKHAND_ADMIN_PASSWORD 24
ok "secrets present"

# =============================================================================
# render .env
# =============================================================================
step "Rendering ${ENV_FILE}"
{
  echo "# generated by init.sh"
  echo "AFTERE_CONFIG=$CONFIG_PATH"; echo "AFTERE_DATA=$DATA_PATH"
  echo "AFTERE_DOMAIN=$DOMAIN"                       # serving domain (staging or prod)
  echo "AFTERE_PRODUCTION_DOMAIN=$PROD_DOMAIN"
  [[ -n "$STAGING_DOMAIN" ]] && echo "AFTERE_STAGING_DOMAIN=$STAGING_DOMAIN"
  echo "AFTERE_MIGRATION=$(answer_get AFTERE_MIGRATION)"
  echo "AFTERE_ADMIN_EMAIL=$(answer_get AFTERE_ADMIN_EMAIL)"
  echo "AUTHENTIK_BOOTSTRAP_EMAIL=$(answer_get AFTERE_ADMIN_EMAIL)"
  echo "TZ=${TZ:-Etc/UTC}"; echo "PUID=1000"; echo "PGID=1000"
  echo "COMPOSE_PROFILES=$(answer_get COMPOSE_PROFILES)"
  echo "AFTERE_IMMICH_ML=$(answer_get AFTERE_IMMICH_ML)"
  echo "AFTERE_REPO=$REPO_BASE"                      # dockhand mounts this checkout
  echo "AFTERE_DOCKHAND=$(answer_get AFTERE_DOCKHAND)"
  echo "AFTERE_DOCKHAND_VHOST=$(answer_get AFTERE_DOCKHAND_VHOST)"
  echo "AFTERE_IMMICH_MAP=$(answer_get AFTERE_IMMICH_MAP)"
  echo "AFTERE_IMMICH_RELEASECHECK=$(answer_get AFTERE_IMMICH_RELEASECHECK)"
  echo "MAIL_OUTBOUND_MODE=$MAILMODE"
  echo "AFTERE_BREAKGLASS=$(answer_get AFTERE_BREAKGLASS | grep -qi '^Yes' && echo yes || echo no)"
  for k in RELAY_HOST RELAY_PORT RELAY_USER RELAY_PASSWORD CERT_MODE \
           PG_AUTHENTIK_PASSWORD PG_NEXTCLOUD_PASSWORD PG_IMMICH_PASSWORD \
           AUTHENTIK_SECRET_KEY AUTHENTIK_BOOTSTRAP_PASSWORD AUTHENTIK_BOOTSTRAP_TOKEN AUTHENTIK_LDAP_TOKEN \
           VAULTWARDEN_ADMIN_TOKEN OIDC_NEXTCLOUD_SECRET OIDC_IMMICH_SECRET OIDC_VAULTWARDEN_SECRET OIDC_ROUNDCUBE_SECRET NEXTCLOUD_ADMIN_PASSWORD \
           LDAP_BIND_PASSWORD STALWART_RECOVERY_PW DOCKHAND_ADMIN_PASSWORD; do
    # single-quote so compose reads values literally (no $ / # interpolation).
    # generated secrets are alphanumeric; the relay password is validated below
    # to exclude ' (which compose's single-quoting cannot escape).
    v="$(answer_get "$k")"; [[ -n "$v" ]] && printf "%s='%s'\n" "$k" "$v"
  done
    _ncu="$(answer_get NEXTCLOUD_ADMIN_USER 2>/dev/null || true)"; printf "NEXTCLOUD_ADMIN_USER='%s'\n" "${_ncu:-ncadmin}"
  echo "IMMICH_DB_USERNAME=immich"; echo "IMMICH_DB_DATABASE=immich"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"; ok ".env written (chmod 600)"

# =============================================================================
# image preflight -> DNS gate -> directories
# =============================================================================
step "Preflighting image tags"
if ! preflight_images; then die "one or more images do not resolve — fix tags in docker-compose.yml."; fi
ok "all images resolve"

step "DNS gate"
bash "$REPO_BASE/dns-setup.sh" || die "DNS gate not passed."

step "Creating directory tree"
mkdir -p \
  "$CONFIG_PATH"/{nginx/conf.d,nginx/snippets,nginx/logs,certs,acme-challenge} \
  "$CONFIG_PATH"/authentik/{db,media,templates,blueprints} \
  "$CONFIG_PATH"/{redis,nextcloud/db,nextcloud/html,stalwart/etc,roundcube,roundcube-db} \
  "$CONFIG_PATH"/immich/{db,ml-cache} \
  "$CONFIG_PATH"/{vaultwarden,crowdsec/config,crowdsec/data,dockhand,dns} \
  "$DATA_PATH"/{nextcloud,stalwart,immich}
ok "directories ready"

# Authentik 2026.5's tenant_files migration does `mkdir /media/public` on EVERY
# boot; the container runs as uid 1000 and can't write a root-owned mount, so a
# fresh deploy crash-loops with PermissionError('/media/public') until the media
# dir is owned by the container uid. (Discovered the hard way upgrading 0818 —
# same wall hits fresh installs on 2026.5.) server + worker share this mount.
chown -R 1000:1000 "$CONFIG_PATH/authentik/media" 2>/dev/null || true

# Stalwart runs as uid 2000 and its RocksDB store needs to CREATE files (LOG
# first of all) directly in the data mount. init.sh's mkdir tree makes everything
# root-owned, so a fresh box crash-looped with:
#   Failed to open database: IO error: ... /var/lib/stalwart//LOG: Permission denied
# Same bug class as the Authentik media chown above — that one got fixed, this one
# was missed. (0829 run.)
if [[ -d "$DATA_PATH/stalwart" ]]; then
  chown -R 2000:2000 "$DATA_PATH/stalwart" 2>/dev/null || true
fi
chown -R 2000:2000 "$CONFIG_PATH/stalwart" 2>/dev/null || true
# Certs are renewed by cert-http.sh as root, so DON'T chown them — grant group
# read instead, or renewal silently re-breaks Stalwart's TLS ~90 days later.
if [[ -d "$CONFIG_PATH/certs" ]]; then
  chgrp -R 2000 "$CONFIG_PATH/certs" 2>/dev/null || true
  chmod -R g+rX "$CONFIG_PATH/certs" 2>/dev/null || true
fi

# --- Stalwart bootstrap pointer ----------------------------------------------
# Stalwart v0.16 opens its setup wizard on any boot where it finds NO config
# file in /etc/stalwart. An empty data store alone does NOT self-initialize —
# that was a misread of a wiped-but-config-present box. The wizard's own first
# write is this one line: a pointer naming the data store. Nothing else (domain,
# hostname, admin) lives here — that's all in the store, set later by
# stalwart-provision.sh. With this file present, a fresh box boots
# "blank-configured" instead of into the wizard, and the provision plan applies
# normally. Content is install-agnostic (in-container path only) and captured
# verbatim from a completed v0.16.16 setup — NOT hand-authored. Seed only if
# absent so a configured server's own config.json is never clobbered on re-run.
STALWART_CFG="$CONFIG_PATH/stalwart/etc/config.json"
if [[ ! -f "$STALWART_CFG" ]]; then
  printf '%s\n' '{"@type":"RocksDb","path":"/var/lib/stalwart/","blobSize":16834,"bufferSize":134217728,"poolWorkers":null}' > "$STALWART_CFG"
  chown 2000:2000 "$STALWART_CFG" 2>/dev/null || true
  ok "seeded Stalwart bootstrap config (config.json)"
else
  ok "Stalwart config.json already present — left as-is"
fi

# --- Roundcube internal-TLS config -------------------------------------------
# Roundcube points at Stalwart by container name over the internal proxy net
# (see docker-compose.yml). Stalwart presents a self-signed cert on that name,
# so peer verification must be relaxed FOR THIS INTERNAL LEG ONLY. This can't be
# done via the ROUNDCUBEMAIL_* env vars, so we seed a config include the image
# auto-loads from /var/roundcube/config. The public leg (browser -> nginx) is
# unaffected and stays fully TLS-verified. Proven qa_10/aftere-0811.
RC_TLS="$CONFIG_PATH/roundcube/aftere-tls.inc.php"
if [[ ! -f "$RC_TLS" ]]; then
  cat > "$RC_TLS" <<'PHP'
<?php
// after-e-: relaxed TLS verify for the INTERNAL webmail->Stalwart hop only.
$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true]];
$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true]];
PHP
  ok "seeded Roundcube internal-TLS config (aftere-tls.inc.php)"
else
  ok "Roundcube aftere-tls.inc.php already present — left as-is"
fi

# =============================================================================
# render Authentik blueprints (domain templated; secrets stay !Env in worker)
# =============================================================================
step "Rendering Authentik blueprints"
if compgen -G "$REPO_BASE/blueprints/*.yaml" >/dev/null; then
  export AFTERE_DOMAIN
  for bp in "$REPO_BASE"/blueprints/*.yaml; do
    envsubst '${AFTERE_DOMAIN}' < "$bp" > "$CONFIG_PATH/authentik/blueprints/$(basename "$bp")"
  done
  ok "$(compgen -G "$REPO_BASE/blueprints/*.yaml" | wc -l) blueprints staged"
else
  warn "no blueprints/ found — SSO apps + LDAP outpost won't be configured."
fi

cd "$REPO_BASE"

# =============================================================================
# identity layer -> readiness -> certs -> vhosts -> full up
# =============================================================================
step "Starting identity layer"
docker compose up -d authentik-db redis authentik-server authentik-worker authentik-ldap
step "Waiting for Authentik worker to seed akadmin"
# server-healthy is NOT the same as the worker having seeded akadmin. Poll for
# the user actually existing, so we never proceed on a half-bootstrapped stack.
akadmin_deadline=$(( SECONDS + 300 ))
until docker compose exec -T authentik-worker ak shell -c \
  "from authentik.core.models import User; import sys; sys.exit(0 if User.objects.filter(username='akadmin').exists() else 1)" \
  >/dev/null 2>&1; do
  (( SECONDS > akadmin_deadline )) && die "worker never seeded akadmin in 5 min — check: docker compose logs authentik-worker"
  sleep 5
done
ok "akadmin seeded"

step "Certificates (mode: $(answer_get CERT_MODE))"
case "$(answer_get CERT_MODE)" in
  http01)
    # honor the staging/production choice from the questionnaire; an explicit
    # STAGING in the environment still wins.
    if [[ -z "${STAGING:-}" ]]; then
      [[ "$(answer_get AFTERE_CERT_STAGING)" == Production* ]] && export STAGING=0 || export STAGING=1
    fi
    bash "$REPO_BASE/cert-http.sh" || warn "cert-http reported failures; some vhosts may be skipped." ;;
  cloudflare) warn "[STUB] Cloudflare DNS-01 not implemented — use http01, or add cert-cloudflare.sh." ;;
  byo)        warn "[STUB] Bring-your-own certs not implemented." ;;
esac

step "Generating nginx vhosts"
# Without a default_server, nginx serves the FIRST-loaded vhost to any request
# whose Host matches nothing — alphabetically that is auth.$DOMAIN, so a missing
# vhost looks like "it redirected me to SSO" instead of like a missing vhost.
# That cost real debugging time on the 0829 run. 444 closes the connection with
# no response, which is also the right answer for bare-IP scanners.
cat > "$CONFIG_PATH/nginx/conf.d/00-default.conf" <<'EOF'
server {
  listen 80 default_server;
  listen 443 ssl default_server;
  server_name _;
  # self-signed placeholder: a default_server that listens on 443 still needs a
  # cert loaded or nginx refuses to start. It is never presented for a real host.
  ssl_certificate     /etc/nginx/certs/_default/fullchain.pem;
  ssl_certificate_key /etc/nginx/certs/_default/privkey.pem;
  # ACME must still work on the catch-all, or a first-issue for a host with no
  # vhost yet would 444 its own challenge.
  location /.well-known/acme-challenge/ { root /var/www/acme-challenge; }
  location / { return 444; }
}
EOF
# Lives under the certs mount, which nginx already has; the leading underscore
# keeps it out of the way of real per-host cert dirs (LE never issues "_default").
mkdir -p "$CONFIG_PATH/certs/_default"
if [[ ! -f "$CONFIG_PATH/certs/_default/fullchain.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=invalid" \
    -keyout "$CONFIG_PATH/certs/_default/privkey.pem" \
    -out    "$CONFIG_PATH/certs/_default/fullchain.pem" >/dev/null 2>&1 \
    && ok "default_server catch-all generated (unmatched hosts get 444)" \
    || { warn "could not generate the default_server cert — removing the catch-all."; rm -f "$CONFIG_PATH/nginx/conf.d/00-default.conf"; }
fi
render_vhost() {
  # BUILD 19b — the `conf=` assignment MUST be its own `local` statement.
  # In a single `local a=$1 b=$a` the right-hand sides are all expanded BEFORE
  # any assignment takes effect, so `$host` there resolved to the CALLER's
  # `host`, not to `$1`. The main loop below is `while read -r host`, so during
  # that loop the global happened to hold the right value and every filename came
  # out correct by luck. The first caller outside the loop (the deferred dockhand
  # vhost) got an empty global and wrote a file literally named ".conf" — while
  # the heredoc body, expanded at run time against the real local, carried the
  # correct server_name. Confirmed on bash 5.2.21.
  local host="$1" up="$2"
  local conf="$CONFIG_PATH/nginx/conf.d/$host.conf"
  # Any future out-of-loop caller hits the same shape, so fail loudly instead of
  # silently producing a stray dotfile in conf.d.
  if [[ -z "$host" ]]; then
    bad "render_vhost called with an empty hostname — refusing to write a vhost."
    return 1
  fi
  local cert="/etc/nginx/certs/$host/fullchain.pem" key="/etc/nginx/certs/$host/privkey.pem"
  if [[ "$up" == REDIRECT:* ]]; then
    local target="${up#REDIRECT:}"
    cat > "$conf" <<EOF
server { listen 80; server_name $host;
  location /.well-known/acme-challenge/ { root /var/www/acme-challenge; }
  location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl; http2 on; server_name $host;
  ssl_certificate $cert; ssl_certificate_key $key;
  location / { return 301 $target\$request_uri; } }
EOF
  else
    # CalDAV/CardDAV service discovery -> Nextcloud, but ONLY on the Nextcloud
    # (apex) host. Exact-match locations take precedence over the catch-all
    # proxy below, so only the well-known paths are intercepted. This is what
    # lets /e/OS (DAVx5) find calendars + contacts in Nextcloud.
    local wellknown=""
    if [[ "$up" == *nextcloud* ]]; then
      wellknown=$'  location = /.well-known/caldav  { return 301 /remote.php/dav/; }\n  location = /.well-known/carddav { return 301 /remote.php/dav/; }'
    fi
    cat > "$conf" <<EOF
server { listen 80; server_name $host;
  location /.well-known/acme-challenge/ { root /var/www/acme-challenge; }
  location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl; http2 on; server_name $host;
  ssl_certificate $cert; ssl_certificate_key $key;
  client_max_body_size 0;
  resolver 127.0.0.11 valid=30s;
  set \$up http://$up;
$wellknown
  location / {
    proxy_pass \$up;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  } }
EOF
  fi
}
rendered=0
while read -r host; do
  [[ -z "$host" ]] && continue
  # dockhand's vhost is deliberately held back: it is written only after the
  # bootstrap below has created the admin and switched auth ON. Until then the
  # panel is loopback-only, so a failed/aborted bootstrap can never leave an
  # unauthenticated docker.sock UI exposed on a public hostname.
  [[ "$host" == "dockhand.$DOMAIN" ]] && continue
  if [[ -f "$CONFIG_PATH/certs/$host/fullchain.pem" ]]; then
    render_vhost "$host" "$(host_upstream "$host" "$DOMAIN")"; rendered=$((rendered+1))
    ok "vhost: $host -> $(host_upstream "$host" "$DOMAIN")"
  else
    warn "no cert for $host — skipping its vhost."
  fi
done < <(active_hosts "$DOMAIN" "$(answer_get COMPOSE_PROFILES)")
ok "$rendered vhost(s) generated"

step "Starting all services"
if [[ ",$PROFILES," == *",mail,"* ]] && check_port25; then
  # something grabbed :25 between the questionnaire and now. If we stopped a unit
  # earlier, retry that disable (non-destructive); we do NOT auto-purge here.
  _u="$(answer_get AFTERE_P25_AUTOSTOP)"
  if [[ -n "$_u" ]]; then
    warn "port 25 got re-occupied since the questionnaire — retrying stop of ${_u}."
    systemctl stop "$_u"    >/dev/null 2>&1 || true
    systemctl disable "$_u" >/dev/null 2>&1 || true
  fi
  if check_port25; then
    _own="$(port25_owner || echo unknown)"
    bad "port 25 is occupied (${_own}) and the mail bring-up would fail."
    echo "  Free it, then re-run. To stop the usual culprit:"
    echo "      systemctl disable --now ${_u:-exim4}"
    echo "      ss -tlnp | grep ':25'"
    die "port 25 conflict at bring-up — resolve and re-run."
  fi
fi
docker compose up -d
if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
  docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 || docker compose restart nginx >/dev/null 2>&1
  ok "nginx reloaded with vhosts"
else
  warn "nginx config test failed — inspect: docker compose exec nginx nginx -t"
fi

# =============================================================================
# Dockhand bootstrap (fail-closed)
# =============================================================================
# Order matters. The panel starts with authentication OFF — that is how the
# product ships — so every call below runs against an unauthenticated API. It is
# safe here ONLY because the port is bound to 127.0.0.1 and we are calling from
# the host itself; nothing off-box can reach it during this window.
#
# Sequence: wait for real JSON -> environment -> adopt stack -> create admin ->
# turn auth ON -> PROVE it is on by making an unauthenticated call that must now
# be rejected. If any step fails we stop the container rather than leave a
# half-configured panel running, and the vhost is never written.
#
# VERIFY AT QA: every endpoint and payload here comes from the contributor's PoC
# against :latest. None of it has been exercised by us. Confirm the shapes (and
# pin DOCKHAND_IMAGE) on a QA box before this is trusted.
if [[ "$(answer_get AFTERE_DOCKHAND)" == yes ]]; then
  step "Bootstrapping Dockhand"
  DH="http://127.0.0.1:3000"
  DH_PW="$(answer_get DOCKHAND_ADMIN_PASSWORD)"
  dh_fail() {
    bad "Dockhand bootstrap failed: $1"
    warn "stopping the container — a panel with auth off will not be left running."
    docker compose stop dockhand >/dev/null 2>&1 || true
    warn "Dockhand is NOT configured. The rest of the stack is unaffected; re-run"
    warn "init.sh after checking: docker compose logs dockhand"
    DOCKHAND_OK=no
  }
  DOCKHAND_OK=yes

  # 1. readiness. The port answers before the app serves JSON (same race as
  #    Authentik), so poll for a real response, not an open socket.
  _ready=no
  for _i in $(seq 1 60); do
    if curl -fsS --max-time 3 "$DH/api/environments" >/dev/null 2>&1; then _ready=yes; break; fi
    sleep 2
  done
  [[ "$_ready" == yes ]] || dh_fail "API never became ready on $DH (60 tries)"

  # 2. environment for this host's local socket
  if [[ "$DOCKHAND_OK" == yes ]]; then
    curl -fsS --max-time 10 "$DH/api/environments" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"$(hostname)\",\"connectionType\":\"socket\",\"socketPath\":\"/var/run/docker.sock\",\"icon\":\"server\"}" \
      >/dev/null 2>&1 || dh_fail "could not create the environment"
  fi

  # 3. adopt this stack. The compose file lives at the mount point declared in
  #    docker-compose.yml, NOT at the host path.
  if [[ "$DOCKHAND_OK" == yes ]]; then
    curl -fsS --max-time 10 "$DH/api/stacks/adopt" -X POST \
      -H 'Content-Type: application/json' \
      -d '{"stacks":[{"name":"aftere","composePath":"/app/data/stacks/aftere/docker-compose.yml"}],"environmentId":1}' \
      >/dev/null 2>&1 || warn "stack adopt failed — Dockhand will still run; adopt it from the UI."
  fi

  # 4. admin user, then 5. auth ON. These two are the security-critical pair:
  #    a user with no auth enabled protects nothing.
  if [[ "$DOCKHAND_OK" == yes ]]; then
    curl -fsS --max-time 10 "$DH/api/users" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"admin\",\"password\":\"${DH_PW}\"}" \
      >/dev/null 2>&1 || dh_fail "could not create the admin user"
  fi
  if [[ "$DOCKHAND_OK" == yes ]]; then
    curl -fsS --max-time 10 "$DH/api/auth/settings" -X PUT \
      -H 'Content-Type: application/json' \
      -d '{"authEnabled":true,"defaultProvider":"local","sessionTimeout":86400}' \
      >/dev/null 2>&1 || dh_fail "could not enable authentication"
  fi

  # 6. prove it. An unauthenticated read must now be refused. curl -f returns
  #    non-zero on 4xx, so SUCCESS here means auth is still off — invert it.
  if [[ "$DOCKHAND_OK" == yes ]]; then
    if curl -fsS --max-time 10 "$DH/api/environments" >/dev/null 2>&1; then
      dh_fail "authentication reports enabled but the API still answers unauthenticated"
    else
      ok "Dockhand authenticated (verified: unauthenticated API calls are refused)"
    fi
  fi

  # 7. only now is a public hostname acceptable.
  if [[ "$DOCKHAND_OK" == yes && "$(answer_get AFTERE_DOCKHAND_VHOST)" == yes ]]; then
    if [[ -f "$CONFIG_PATH/certs/dockhand.$DOMAIN/fullchain.pem" ]]; then
      render_vhost "dockhand.$DOMAIN" "$(host_upstream "dockhand.$DOMAIN" "$DOMAIN")"
      if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 || docker compose restart nginx >/dev/null 2>&1
        ok "vhost: dockhand.$DOMAIN -> dockhand:3000"
      else
        warn "nginx rejected the dockhand vhost — inspect: docker compose exec nginx nginx -t"
      fi
    else
      warn "no cert for dockhand.$DOMAIN — vhost not written. Reach it over an SSH tunnel"
      warn "until the cert exists, then re-run init.sh."
    fi
  fi
fi

step "Wiring the LDAP outpost token"
# Authentik auto-generates the outpost token (can't be injected — #9711); read
# it back and feed it to the container. Needs auth.$DOMAIN served (it is now).
bash "$REPO_BASE/ldap-token.sh" || warn "LDAP outpost token wiring failed — run ./ldap-token.sh manually (needs the 20-ldap blueprint applied)."

step "Wiring the LDAP bind account app-password"
# aftere-ldap-bind's app-password (LDAP_BIND_PASSWORD) — read back, then consumed
# by stalwart-provision.sh as the directory bind secret.
bash "$REPO_BASE/ldap-bind.sh" || warn "LDAP bind-password wiring failed — run ./ldap-bind.sh manually before stalwart-provision.sh."

# =============================================================================
# finish
# =============================================================================
step "Phase 1 complete"
echo "  Secrets are durable in ${ENV_FILE} (chmod 600) — BACK THIS UP OFF THIS BOX."

printf '\n  %s──── admin login (save to your password manager OFF this box, then scrub) ────%s\n' "$c_warn" "$c_end"
printf '    Authentik admin user: %sakadmin%s   (you can also sign in with %s)\n' "$c_bold" "$c_end" "$(getcfg AFTERE_ADMIN_EMAIL)"
printf '    Password:             %s%s%s\n' "$c_bold" "$(getcfg AUTHENTIK_BOOTSTRAP_PASSWORD)" "$c_end"
printf '    Sign in at:           https://auth.%s   (change the password after first login)\n' "$DOMAIN"
printf '  %s──── end admin login ────%s\n' "$c_warn" "$c_end"

rm -f "$ANSWER_FILE"

# BUILD 19b — everything below this line runs AFTER answers.env is gone, so it
# reads .env via getcfg. answer_get here returns empty and sed complains to the
# console ("can't read .../answers.env"), which is how the 0829 run printed a
# blank Dockhand password and took the tunnel branch on a vhost install.
_dh_vhost="$(getcfg AFTERE_DOCKHAND_VHOST 2>/dev/null || true)"
_dh_pass="$(getcfg DOCKHAND_ADMIN_PASSWORD 2>/dev/null || true)"

_has_mail=no;    [[ ",$PROFILES," == *",mail,"* ]] && _has_mail=yes
_is_staging=no;  [[ "$(getcfg AFTERE_CERT_STAGING)" == Staging* ]] && _is_staging=yes

cat <<EOF

  Reachable now (HTTPS on the serving domain, ${DOMAIN}):
    https://$DOMAIN            Nextcloud (auto-installed; run nextcloud-provision.sh for login)
    https://auth.$DOMAIN       Authentik  (login: akadmin or your admin email + the password above)
$( [[ ",$PROFILES," == *",vault,"* ]]  && echo "    https://vault.$DOMAIN      Vaultwarden" )
$( [[ ",$PROFILES," == *",photos,"* ]] && echo "    https://immich.$DOMAIN     Immich" )
$( [[ "${DOCKHAND_OK:-no}" == yes && "$_dh_vhost" == yes ]] && echo "    https://dockhand.$DOMAIN   Dockhand (login: admin)" )
$( [[ "$(getcfg AFTERE_MIGRATION)" == yes ]] && echo "  Migrating? Real users (e.g. your own email) are created with new-user.sh — akadmin is just the bootstrap admin." )
EOF

# ---- where do I go from here? ----------------------------------------------
_has_relay=no; [[ "$(getcfg MAIL_OUTBOUND_MODE 2>/dev/null)" == relay ]] && _has_relay=yes
echo
echo "  Next steps"
echo "    1. Sign in to Authentik at https://auth.$DOMAIN with the admin login above, and change the password."
_n=2
if [[ "$_has_mail" == yes ]]; then
  # provision BEFORE new-user: new-user.sh now refuses to run until the mail
  # backend exists (it'd otherwise make a user whose mailbox silently fails).
  echo "    ${_n}. Set up mail:  sudo bash stalwart-provision.sh"; _n=$((_n+1))
  if [[ "$_has_relay" == yes ]]; then
    echo "    ${_n}. Turn on outbound relay:  sudo bash relay-setup.sh"; _n=$((_n+1))
  fi
  echo "    ${_n}. Configure Nextcloud (proxy + LDAP login + apps):  sudo bash nextcloud-provision.sh"; _n=$((_n+1))
  echo "    ${_n}. Create your first user:  sudo bash new-user.sh"; _n=$((_n+1))
  echo "    ${_n}. Try it out — sign in at https://$DOMAIN, and webmail at https://webmail.$DOMAIN."
else
  echo "    ${_n}. Create your first user:  sudo bash new-user.sh"; _n=$((_n+1))
  echo "    ${_n}. Try it out — sign in at https://$DOMAIN."
fi
echo
if [[ "$_has_mail" == yes && "$_has_relay" == yes ]]; then
  echo "  Outbound goes through your relay: your SPF must authorize the RELAY, not this VM (use the"
  echo "  include line your provider gives you), and publish the relay's DKIM if it signs your mail."
fi
[[ "$_is_staging" == yes ]] && \
  echo "  Once everything looks right, swap your staging certs for real ones:  sudo STAGING=0 bash cert-http.sh"
echo "  Nextcloud login (LDAP) is set up by nextcloud-provision.sh above. Immich / Vault OIDC tiles are still in progress."

# ---- Dockhand credentials (shown once) -------------------------------------
if [[ "${DOCKHAND_OK:-no}" == yes ]]; then
  echo
  echo "  Dockhand — shown once, it is also in .env as DOCKHAND_ADMIN_PASSWORD"
  echo "    username: admin"
  echo "    password: ${_dh_pass:-<see DOCKHAND_ADMIN_PASSWORD in .env>}"
  if [[ "$_dh_vhost" == yes ]]; then
    echo "    at:       https://dockhand.$DOMAIN"
  else
    echo "    Reach it by tunnelling from your workstation:"
    echo "        ssh -L 3000:127.0.0.1:3000 $(whoami)@$DOMAIN"
    echo "    then browse http://localhost:3000"
  fi
  echo "    ${c_dim}It holds the Docker socket: whoever logs in owns this box. Do not"
  echo "    republish port 3000 on a public interface.${c_end}"
fi

# ---- warnings roll-up ------------------------------------------------------
if [[ -s "$AFTERE_WARN_LOG" ]]; then
  echo
  printf '  %sSome steps reported warnings — worth a look before you rely on this box:%s\n' "${c_warn}" "${c_end}"
  awk '!seen[$0]++' "$AFTERE_WARN_LOG" | sed 's/^/    - /'
fi
rm -f "$AFTERE_WARN_LOG" 2>/dev/null || true
ok "done"
