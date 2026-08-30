#!/usr/bin/env bash
# =============================================================================
# after-e- — common.sh   (sourced by every script; not run directly)
# =============================================================================
# Single source of truth for: repo location, output helpers, config reading,
# the hostname model (list + nginx upstream map), image-tag preflight, and the
# container-health readiness waiter. Fixes the "each script re-hardcodes this"
# drift by putting it in exactly one place.
# =============================================================================

# --- output helpers ----------------------------------------------------------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_dim=$'\e[2m'; c_bold=$'\e[1m'; c_end=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$c_dim" "$c_end" "$*"; }
ok()   { printf '    %sok%s   %s\n' "$c_ok" "$c_end" "$*"; }
warn() {
  printf '    %swarn%s %s\n' "$c_warn" "$c_end" "$*"
  # opt-in roll-up: if a run set AFTERE_WARN_LOG, collect warnings so the closer
  # can list "what didn't fully succeed" at the end. Never affects warn()'s exit.
  [[ -n "${AFTERE_WARN_LOG:-}" ]] && printf '%s\n' "$*" >> "$AFTERE_WARN_LOG" 2>/dev/null
  return 0
}
bad()  { printf '    %sFAIL%s %s\n' "$c_err" "$c_end" "$*"; }
die()  { printf '    %sFATAL%s %s\n' "$c_err" "$c_end" "$*" >&2; exit 1; }

# --- REPO_BASE: walk up from THIS file's dir until docker-compose.yml is found
# (fixes the "$(dirname)/.." assumption that broke on a flat layout).
_cf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_BASE=""
_d="$_cf_dir"
while [[ "$_d" != "/" ]]; do
  if [[ -f "$_d/docker-compose.yml" ]]; then REPO_BASE="$_d"; break; fi
  _d="$(dirname "$_d")"
done
if [[ -z "$REPO_BASE" ]]; then
  printf '    %sFATAL%s docker-compose.yml not found searching upward from %s\n' \
    "$c_err" "$c_end" "$_cf_dir" >&2
  printf '           Keep the scripts in the same directory as docker-compose.yml.\n' >&2
  exit 1
fi
ENV_FILE="$REPO_BASE/.env"
ANSWER_FILE="$REPO_BASE/answers.env"
COMPOSE_FILE="$REPO_BASE/docker-compose.yml"

# --- config reader: prefer .env, fall back to answers.env --------------------
getcfg() {
  local f v
  for f in "$ENV_FILE" "$ANSWER_FILE"; do
    [[ -r "$f" ]] || continue
    v="$(sed -n "s/^$1=//p" "$f" | head -n1)"
    [[ -z "$v" ]] && continue
    # .env values are single-quoted so compose reads them literally; shell
    # consumers need them bare. Strip one matching pair of surrounding quotes.
    if   [[ "$v" == \'*\' ]]; then v="${v#\'}"; v="${v%\'}"
    elif [[ "$v" == \"*\" ]]; then v="${v#\"}"; v="${v%\"}"; fi
    echo "$v"; return 0
  done
  return 1
}

# =============================================================================
# HOSTNAME MODEL  (#7 — the one definition everything reads)
# =============================================================================
# has_profile <name> — true if COMPOSE_PROFILES (arg 2, or from cfg) contains it
_profiles_str() { getcfg COMPOSE_PROFILES 2>/dev/null || true; }

# active_hosts <domain> <profiles> — prints every active hostname, one per line
active_hosts() {
  local domain="$1" profiles="$2"
  echo "$domain"                       # Nextcloud (apex)
  echo "auth.$domain"                  # Authentik
  [[ ",$profiles," == *",photos,"* ]] && echo "immich.$domain"
  [[ ",$profiles," == *",vault,"*  ]] && echo "vault.$domain"
  if [[ ",$profiles," == *",mail,"* ]]; then
    printf '%s\n' "mail.$domain" "stalwart.$domain" "webmail.$domain" \
                  "autoconfig.$domain" "autodiscover.$domain" "mta-sts.$domain"
  fi
  # Dockhand only gets a hostname when the operator chose the vhost route. The
  # marker profile "dockhand-vhost" carries that choice through the same
  # profiles string every other host keys on, so dns-setup's gate and
  # cert-http's SAN list pick it up with no extra config reads. (Compose
  # ignores a profile no service declares — same trick as immich-ml.)
  [[ ",$profiles," == *",dockhand-vhost,"* ]] && echo "dockhand.$domain"
  return 0
}

# all_hosts <domain> — every hostname ANY tier could use, ignoring profiles.
# dns-setup uses this so the advisory always shows mail./webmail./etc. (the ones
# that gate cert issuance) even when run before init sets COMPOSE_PROFILES.
all_hosts() {
  local domain="$1"
  printf '%s\n' "$domain" "auth.$domain" "immich.$domain" "vault.$domain" \
                 "mail.$domain" "stalwart.$domain" "webmail.$domain" \
                 "autoconfig.$domain" "autodiscover.$domain" "mta-sts.$domain"
}

# host_upstream <host> <domain> — nginx target for a hostname:
#   "container:port"     -> reverse-proxy to that upstream
#   "REDIRECT:https://x" -> 301 redirect (no app behind it)
# VERIFY AT QA: the stalwart:8080 targets for autoconfig/autodiscover/mta-sts
# assume Stalwart serves those over its HTTP listener on 8080.
host_upstream() {
  local host="$1" domain="$2"
  case "$host" in
    "$domain")              echo "nextcloud:80" ;;
    "auth.$domain")         echo "authentik-server:9000" ;;
    "immich.$domain")       echo "immich-server:2283" ;;
    "vault.$domain")        echo "vaultwarden:80" ;;
    "webmail.$domain")      echo "roundcube:80" ;;
    "stalwart.$domain")     echo "stalwart:8080" ;;
    "autoconfig.$domain")   echo "stalwart:8080" ;;
    "autodiscover.$domain") echo "stalwart:8080" ;;
    "mta-sts.$domain")      echo "stalwart:8080" ;;
    "mail.$domain")         echo "REDIRECT:https://webmail.$domain" ;;
    "dockhand.$domain")     echo "dockhand:3000" ;;
    *)                      echo "" ;;
  esac
}

# apex_hosts <domain> — the hostnames that MUST be A records, never CNAMEs:
#   the apex   : a CNAME at the zone apex is illegal (RFC 1034 3.6.2)
#   mail.      : it is the MX target, and an MX must not name a CNAME
#                (RFC 2181 10.3) — some receivers reject outright.
# Everything else in the host model CNAMEs to the apex, so an IP change is a
# one-record edit. dns-setup renders and enforces this split.
apex_hosts() { printf '%s\n' "$1" "mail.$1"; }

# is_apex_host <host> <domain> — true for a host that must remain an A record
is_apex_host() { [[ "$1" == "$2" || "$1" == "mail.$2" ]]; }

# =============================================================================
# IMAGE-TAG PREFLIGHT (#9) — check every compose image resolves BEFORE pulling
# =============================================================================
preflight_images() {
  local missing=0 img err rc
  while read -r img; do
    [[ -z "$img" ]] && continue
    printf '    %-54s ' "$img"
    # 1) already pulled locally? then it exists, full stop (no registry query).
    if docker image inspect "$img" >/dev/null 2>&1; then
      printf '%sok%s (cached locally)\n' "$c_ok" "$c_end"; continue
    fi
    # 2) not local -> ask the registry, but tell "tag doesn't exist" apart from
    #    "couldn't reach / rate-limited" (Docker Hub throttles anonymous queries).
    err="$(docker manifest inspect "$img" 2>&1 >/dev/null)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '%sok%s\n' "$c_ok" "$c_end"
    elif printf '%s' "$err" | grep -qiE 'no such manifest|manifest unknown'; then
      printf '%sMISSING%s (tag not found in registry)\n' "$c_err" "$c_end"; missing=$((missing+1))
    else
      printf '%sunverified%s (%s)\n' "$c_warn" "$c_end" "$(printf '%s' "$err" | head -n1 | cut -c1-46)"
    fi
  done < <(grep -E '^[[:space:]]*image:' "$COMPOSE_FILE" | awk '{print $2}' | sort -u)
  return "$missing"
}

# =============================================================================
# READINESS — poll the Authentik API until it returns valid JSON (qa_14)
# =============================================================================
# On a fresh bring-up the API port answers before the app serves JSON — nginx/the
# proxy hands back an HTML error page, and jq chokes ("Invalid numeric literal").
# Call this at the top of any script that hits the API, AFTER $API/$TOKEN are set
# and BEFORE the first real call. The inter-poll sleep is a loop interval, NOT a
# fixed pre-wait — it returns the instant the API is actually ready.
wait_for_authentik_api() {
  local api="$1" tok="$2" deadline=$(( SECONDS + 180 ))
  step "Waiting for the Authentik API to serve JSON"
  while :; do
    if curl -sk --connect-timeout 5 --max-time 15 \
         -H "Authorization: Bearer $tok" "$api/outposts/instances/" \
         | jq -e . >/dev/null 2>&1; then
      ok "Authentik API ready"; return 0
    fi
    (( SECONDS > deadline )) && die "Authentik API not returning JSON after 180s — check: docker compose logs authentik-server"
    sleep 5
  done
}

# =============================================================================
# READINESS (#3) — poll a container's HEALTH via docker inspect (no host port)
# =============================================================================
wait_healthy() {
  local name="$1" timeout="${2:-300}" waited=0 st
  while :; do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealthcheck{{end}}' "$name" 2>/dev/null || echo missing)"
    case "$st" in
      healthy)       return 0 ;;
      nohealthcheck) return 0 ;;   # image defines no healthcheck; treat "running" as ready
    esac
    (( waited >= timeout )) && return 1
    sleep 3; waited=$((waited + 3))
  done
}
