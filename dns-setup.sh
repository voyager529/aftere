#!/usr/bin/env bash
# =============================================================================
# after-e- — dns-setup.sh   [SECOND DRAFT]
# =============================================================================
# Shows exactly which DNS records to create (computed from the shared hostname
# model in common.sh), then loops checking A + MX (blocking) and PTR (advisory)
# against the AUTHORITATIVE nameserver until all pass or Ctrl+C.
# Phase-2 mail-auth records (SPF/DMARC/MTA-STS/DKIM) are shown, not blocked on.
# =============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

command -v dig >/dev/null 2>&1 || die "dig is required (run prereqs.sh)."

DOMAIN="$(getcfg AFTERE_DOMAIN || true)"
[[ -z "$DOMAIN" ]] && read -r -p "  Primary domain: " DOMAIN < /dev/tty
[[ -n "$DOMAIN" ]] || die "no domain."
PROFILES="$(getcfg COMPOSE_PROFILES || true)"
MAIL_MODE="$(getcfg MAIL_OUTBOUND_MODE || echo none)"
RELAY_HOST="$(getcfg RELAY_HOST || true)"
MAIL_ON=false; [[ ",$PROFILES," == *",mail,"* ]] && MAIL_ON=true

# --- public IP (override with PUBLIC_IP=...) --------------------------------
PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -n1 || true)"
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -fsS -4 https://api.ipify.org 2>/dev/null || true)"
fi
[[ "$PUBLIC_IP" =~ ^[0-9.]+$ ]] || die "could not detect public IPv4. Set PUBLIC_IP=x.x.x.x and re-run."

AUTH_NS="$(dig +short NS "$DOMAIN" | head -n1)"
if [[ -z "$AUTH_NS" ]]; then warn "no authoritative NS for $DOMAIN yet — using default resolver."; NS_ARG=(); else NS_ARG=("@$AUTH_NS"); fi

mapfile -t HOSTS < <(active_hosts "$DOMAIN" "$PROFILES")       # deployed set — drives the resolve GATE
mapfile -t PRINT_HOSTS < <(all_hosts "$DOMAIN")                # full roster — advisory DISPLAY (always shows mail. etc.)

# =============================================================================
# DISPLAY
# =============================================================================
step "DNS records for ${c_bold}${DOMAIN}${c_end}  (server public IP: ${c_bold}${PUBLIC_IP}${c_end})"
echo
echo "  ${c_bold}A records${c_end} (add AAAA too if you have IPv6):"
printf '    %-28s %-6s %s\n' HOST TYPE VALUE
for h in "${PRINT_HOSTS[@]}"; do printf '    %-28s %-6s %s\n' "$h" A "$PUBLIC_IP"; done

if $MAIL_ON; then
  echo; echo "  ${c_bold}MX${c_end} (required even in relay mode):"
  printf '    %-28s %-6s %s\n' "$DOMAIN" MX "10 mail.$DOMAIN"
  if [[ "$MAIL_MODE" == direct ]]; then
    echo; echo "  ${c_bold}PTR${c_end} (advisory; set at your host provider):"
    printf '    %-28s %-6s %s\n' "$PUBLIC_IP" PTR "mail.$DOMAIN"
  fi
  case "$MAIL_MODE" in
    relay) case "$RELAY_HOST" in
             *mailgun*) SPF="v=spf1 a mx include:mailgun.org ~all" ;;
             *smtp2go*) SPF="v=spf1 a mx include:spf.smtp2go.com ~all" ;;
             *)         SPF="v=spf1 a mx include:<your-relay-spf> ~all" ;;
           esac ;;
    *)     SPF="v=spf1 a mx ip4:${PUBLIC_IP} ~all" ;;
  esac
  echo; echo "  ${c_bold}Phase 2 — mail auth${c_end} ${c_dim}(create SPF/DMARC/TLS-RPT/MTA-STS now if you like; not blocked here. DKIM comes from postinstall.)${c_end}"
  printf '    %-28s %-6s %s\n' "$DOMAIN"            TXT "$SPF"
  printf '    %-28s %-6s %s\n' "_dmarc.$DOMAIN"     TXT "v=DMARC1; p=quarantine; rua=mailto:postmaster@$DOMAIN; adkim=r; aspf=r"
  printf '    %-28s %-6s %s\n' "_smtp._tls.$DOMAIN" TXT "v=TLSRPTv1; rua=mailto:postmaster@$DOMAIN"
  printf '    %-28s %-6s %s\n' "_mta-sts.$DOMAIN"   TXT "v=STSv1; id=$(date +%Y%m%d%H%M)"
fi

echo; read -r -p "  Create the A/MX records above, then press Enter to check (Ctrl+C to abort)... " _ < /dev/tty

# =============================================================================
# CHECK LOOP
# =============================================================================
qA()  { dig +short "${NS_ARG[@]}" A "$1" | tr -d '\r'; }
qMX() { dig +short "${NS_ARG[@]}" MX "$1" | awk '{print $2}' | sed 's/\.$//' | tr -d '\r'; }
qPTR(){ dig -x "$1" +short | sed 's/\.$//' | tr -d '\r'; }

round=0
while true; do
  round=$((round+1)); step "Check round $round"; fails=0
  for h in "${HOSTS[@]}"; do
    if qA "$h" | grep -qx "$PUBLIC_IP"; then ok "A  $h -> $PUBLIC_IP"
    else bad "A  $h -> expected $PUBLIC_IP, got '$(qA "$h" | paste -sd, -)'"; fails=$((fails+1)); fi
  done
  if $MAIL_ON; then
    if qMX "$DOMAIN" | grep -qx "mail.$DOMAIN"; then ok "MX $DOMAIN -> mail.$DOMAIN"
    else bad "MX $DOMAIN -> expected mail.$DOMAIN, got '$(qMX "$DOMAIN" | paste -sd, -)'"; fails=$((fails+1)); fi
    if [[ "$MAIL_MODE" == direct ]]; then
      [[ "$(qPTR "$PUBLIC_IP")" == "mail.$DOMAIN" ]] \
        && ok "PTR $PUBLIC_IP -> mail.$DOMAIN" \
        || warn "PTR $PUBLIC_IP -> '$(qPTR "$PUBLIC_IP" || true)' (advisory; not blocking)"
    fi
  fi
  if (( fails == 0 )); then step "All required records resolve. ${c_ok}DNS gate passed.${c_end}"; exit 0; fi
  printf '\n  %d required record(s) still failing.\n' "$fails"
  read -r -p "  Press Enter to re-check (Ctrl+C to abort)... " _ < /dev/tty
done
