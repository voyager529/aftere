#!/usr/bin/env bash
# =============================================================================
# after-e- — log-retention.sh   [build 20]
# =============================================================================
# Writes /etc/logrotate.d/aftere for the nginx access/error logs.
#
#   bash log-retention.sh                 # defaults: 15 days, 100M
#   bash log-retention.sh 30              # 30 days, 100M
#   bash log-retention.sh 30 250M         # 30 days, 250M
#
# WHY BOTH a day count and a size cap: 15 days of retention does not help if a
# scanner or a bad bot burst fills the disk on day two. maxsize rotates early
# under load, so the ceiling is bounded at roughly <rotate> files rather than
# <rotate> days.
#
# WHY NOT copytruncate: it can drop lines mid-write, and it resets the file
# offset under CrowdSec, which tails these same files. Instead the postrotate
# hook sends nginx SIGUSR1 (its reopen signal) so it lets go of the rotated
# inode. Without that, nginx keeps writing to a deleted file: the disk fills,
# the logs look empty, and nothing errors.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DAYS="${1:-15}"
MAXSIZE="${2:-100M}"
DROPIN="/etc/logrotate.d/aftere"

[[ "$DAYS" =~ ^[0-9]+$ ]]        || die "days must be a number (got '$DAYS')."
(( DAYS >= 1 ))                  || die "days must be at least 1."
[[ "$MAXSIZE" =~ ^[0-9]+[kKmMgG]$ ]] || die "maxsize must look like 100M or 2G (got '$MAXSIZE')."
[[ "$(id -u)" == 0 ]]            || die "run as root — this writes to /etc/logrotate.d."

command -v logrotate >/dev/null 2>&1 || die "logrotate is not installed (run prereqs.sh)."

LOGS_PATH="$(getcfg AFTERE_LOGS || true)"
[[ -n "$LOGS_PATH" ]] || die "AFTERE_LOGS not found in .env — run init.sh first."

step "Log retention: ${c_bold}${DAYS}${c_end} days, rotate early at ${c_bold}${MAXSIZE}${c_end}"

# Written to a temp file and validated with `logrotate -d` (dry run) BEFORE it is
# installed, so a bad drop-in can never break the nightly run for every other
# service on the box.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# after-e- — managed by log-retention.sh. Edit via that script, not by hand.
${LOGS_PATH}/nginx/*.log {
    daily
    rotate ${DAYS}
    maxsize ${MAXSIZE}
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        # SIGUSR1 = reopen log files. Works with no compose context, so it does
        # not care what directory cron runs from.
        docker kill -s USR1 aftere-nginx >/dev/null 2>&1 || true
    endscript
}
EOF

if logrotate -d "$TMP" >/dev/null 2>&1; then
  install -m 0644 "$TMP" "$DROPIN"
  ok "installed ${DROPIN}"
else
  warn "logrotate rejected the generated config — NOT installing. Detail:"
  logrotate -d "$TMP" 2>&1 | sed 's/^/    /' | tail -20
  die "log retention unchanged."
fi

echo
echo "  Rotation runs on logrotate's normal schedule (usually a nightly cron/timer),"
echo "  at local midnight — so it follows the timezone chosen during init."
echo "  Force a run to check:   logrotate -f ${DROPIN}"
echo
echo "  ${c_dim}VERIFY AT QA: after a forced rotation, confirm CrowdSec still fires."
echo "  It tails these files read-only and should follow the new one, but a"
echo "  rotation that silently blinds CrowdSec looks exactly like nothing wrong.${c_end}"
