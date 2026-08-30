#!/usr/bin/env bash
# =============================================================================
# after-e- — dns-setup.sh   [build 19]
# =============================================================================
# Shows exactly which DNS records to create (computed from the shared hostname
# model in common.sh), writes a copy/paste-ready zone snippet, then loops
# checking A/CNAME + MX (blocking) and PTR (advisory) against the AUTHORITATIVE
# nameserver until all pass or Ctrl+C.
#
# RECORD MODEL (build 19): only the apex and mail. are A records — everything
# else CNAMEs to the apex, so a server IP change is a one-record edit. See
# apex_hosts() in common.sh for why those two cannot be CNAMEs.
#
# Phase-2 mail-auth records (SPF/DMARC/MTA-STS) are shown, not blocked on.
# DKIM is deliberately absent: Stalwart mints it post-install and is the
# authoritative source — two generators would produce a duplicate, wrong record.
#
# ZONE=1 bash dns-setup.sh  — also print the zone snippet inline.
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
CONFIG_PATH="$(getcfg AFTERE_CONFIG || true)"
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
# DISPLAY roster = full roster UNION the active set. all_hosts alone would miss
# optional, non-tier hosts (dockhand.) and the gate would then block on a record
# the operator was never shown. Union keeps display >= gate, always.
mapfile -t PRINT_HOSTS < <({ all_hosts "$DOMAIN"; active_hosts "$DOMAIN" "$PROFILES"; } | awk '!seen[$0]++')

# label <fqdn> — the zone-relative label ("@" for the apex)
label() { local h="$1"; [[ "$h" == "$DOMAIN" ]] && { echo '@'; return; }; echo "${h%.$DOMAIN}"; }

# --- SPF value depends on who actually sends -------------------------------
SPF=""
if $MAIL_ON; then
  case "$MAIL_MODE" in
    relay) case "$RELAY_HOST" in
             *mailgun*) SPF="v=spf1 a mx include:mailgun.org ~all" ;;
             *smtp2go*) SPF="v=spf1 a mx include:spf.smtp2go.com ~all" ;;
             *)         SPF="v=spf1 a mx include:<your-relay-spf> ~all" ;;
           esac ;;
    *)     SPF="v=spf1 a mx ip4:${PUBLIC_IP} ~all" ;;
  esac
fi
DMARC="v=DMARC1; p=quarantine; rua=mailto:postmaster@$DOMAIN; adkim=r; aspf=r"
TLSRPT="v=TLSRPTv1; rua=mailto:postmaster@$DOMAIN"
STSID="v=STSv1; id=$(date +%Y%m%d%H%M)"

# =============================================================================
# DISPLAY  (table — what most registrar web forms want)
# =============================================================================
step "DNS records for ${c_bold}${DOMAIN}${c_end}  (server public IP: ${c_bold}${PUBLIC_IP}${c_end})"
echo
echo "  ${c_bold}A records${c_end} — these two cannot be CNAMEs (add AAAA too if you have IPv6):"
printf '    %-28s %-6s %s\n' HOST TYPE VALUE
while read -r h; do printf '    %-28s %-6s %s\n' "$h" A "$PUBLIC_IP"; done < <(apex_hosts "$DOMAIN")

echo
echo "  ${c_bold}CNAME records${c_end} ${c_dim}(all point at the apex — a server IP change is then a one-record edit)${c_end}:"
printf '    %-28s %-6s %s\n' HOST TYPE VALUE
for h in "${PRINT_HOSTS[@]}"; do
  is_apex_host "$h" "$DOMAIN" && continue
  printf '    %-28s %-6s %s\n' "$h" CNAME "$DOMAIN"
done

if $MAIL_ON; then
  echo; echo "  ${c_bold}MX${c_end} (required even in relay mode):"
  printf '    %-28s %-6s %s\n' "$DOMAIN" MX "10 mail.$DOMAIN"
  if [[ "$MAIL_MODE" == direct ]]; then
    echo; echo "  ${c_bold}PTR / reverse DNS${c_end} ${c_dim}(advisory — never blocks)${c_end}:"
    printf '    %-28s %-6s %s\n' "$PUBLIC_IP" PTR "mail.$DOMAIN"
    echo "    ${c_dim}Set this at your VM/host provider — the console that owns the IP — not at"
    echo "    your DNS registrar; reverse DNS lives in the provider's zone. Sending"
    echo "    without it costs real deliverability at the big mailbox providers.${c_end}"
  fi
  echo; echo "  ${c_bold}Phase 2 — mail auth${c_end} ${c_dim}(create these now if you like; not blocked here. DKIM comes from Stalwart post-install.)${c_end}"
  printf '    %-28s %-6s %s\n' "$DOMAIN"            TXT "$SPF"
  printf '    %-28s %-6s %s\n' "_dmarc.$DOMAIN"     TXT "$DMARC"
  printf '    %-28s %-6s %s\n' "_smtp._tls.$DOMAIN" TXT "$TLSRPT"
  printf '    %-28s %-6s %s\n' "_mta-sts.$DOMAIN"   TXT "$STSID"
fi

# =============================================================================
# ZONE SNIPPET  (for providers whose UI accepts a paste)
# =============================================================================
ZONE_OUT=""
if [[ -n "$CONFIG_PATH" ]] && mkdir -p "$CONFIG_PATH/dns" 2>/dev/null; then
  ZONE_OUT="$CONFIG_PATH/dns/zone.txt"
else
  ZONE_OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zone.txt"
fi

build_zone() {
  printf '$ORIGIN %s.\n' "$DOMAIN"
  printf '$TTL 3600\n'
  echo "; after-e- — DNS import snippet for ${DOMAIN}   (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "; NOT a loadable zone file: no SOA, no NS. Paste into a provider's zone-import"
  echo "; box, or read it while filling in their web form."
  echo ";"
  echo "; --- A --- these two must NOT be CNAMEs: a CNAME at the apex is invalid, and"
  echo ";           an MX target must not name a CNAME (mail gets rejected)."
  while read -r h; do printf '%s\tIN\tA\t%s\n' "$(label "$h")" "$PUBLIC_IP"; done < <(apex_hosts "$DOMAIN")
  echo ";"
  echo "; --- CNAME --- everything else points at the apex"
  for h in "${PRINT_HOSTS[@]}"; do
    is_apex_host "$h" "$DOMAIN" && continue
    printf '%s\tIN\tCNAME\t%s.\n' "$(label "$h")" "$DOMAIN"
  done
  if $MAIL_ON; then
    echo ";"
    echo "; --- MX ---"
    printf '@\tIN\tMX\t10 mail.%s.\n' "$DOMAIN"
    echo ";"
    echo "; --- mail auth (TXT) ---"
    printf '@\tIN\tTXT\t"%s"\n'          "$SPF"
    printf '_dmarc\tIN\tTXT\t"%s"\n'     "$DMARC"
    printf '_smtp._tls\tIN\tTXT\t"%s"\n' "$TLSRPT"
    printf '_mta-sts\tIN\tTXT\t"%s"\n'   "$STSID"
    echo "; DKIM is NOT here on purpose — Stalwart generates the key and is the"
    echo "; authoritative source for that record. Publish it after provisioning."
    if [[ "$MAIL_MODE" == direct ]]; then
      echo ";"
      echo "; --- PTR (advisory) --- not part of this zone. Set reverse DNS at your"
      echo ";     VM provider:  ${PUBLIC_IP} -> mail.${DOMAIN}"
    fi
  fi
}

if build_zone > "$ZONE_OUT" 2>/dev/null; then
  chmod 644 "$ZONE_OUT" 2>/dev/null || true
  echo; ok "zone snippet written: ${c_bold}${ZONE_OUT}${c_end}  ${c_dim}(ZONE=1 to print it here)${c_end}"
else
  warn "could not write a zone snippet to ${ZONE_OUT} — the table above is authoritative."
  ZONE_OUT=""
fi
if [[ "${ZONE:-0}" == 1 && -n "$ZONE_OUT" ]]; then
  echo; echo "  ${c_bold}--- 8< --- zone snippet --- 8< ---${c_end}"; echo
  sed 's/^/  /' "$ZONE_OUT"
  echo; echo "  ${c_bold}--- 8< --- end --- 8< ---${c_end}"
fi

echo; read -r -p "  Create the records above, then press Enter to check (Ctrl+C to abort)... " _ < /dev/tty

# =============================================================================
# CHECK LOOP
# =============================================================================
qA()   { dig +short "${NS_ARG[@]}" A "$1" | tr -d '\r'; }
qCN()  { dig +short "${NS_ARG[@]}" CNAME "$1" | sed 's/\.$//' | tr -d '\r'; }
qMX()  { dig +short "${NS_ARG[@]}" MX "$1" | awk '{print $2}' | sed 's/\.$//' | tr -d '\r'; }
qPTR() { dig -x "$1" +short | sed 's/\.$//' | tr -d '\r'; }

# resolve_ip <host> — the A address(es), following a CNAME either way.
# +short A returns the chain (CNAME lines, then the address), so filter to IPv4.
# An authoritative server only chases IN-ZONE targets; if the operator pointed a
# CNAME out of zone we get a bare CNAME and no address, so fall back to the
# recursive resolver rather than false-failing.
resolve_ip() {
  local h="$1" out
  out="$(qA "$h" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  if [[ -z "$out" && -n "$(qCN "$h")" ]]; then
    out="$(dig +short A "$h" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  fi
  printf '%s\n' "$out"
}

PTR_NOTE=""
round=0
while true; do
  round=$((round+1)); step "Check round $round"; fails=0

  for h in "${HOSTS[@]}"; do
    _cn="$(qCN "$h")"
    # The failure this record model actually invites: someone CNAMEs the apex or
    # mail. along with everything else. Both still resolve to an address, so an
    # address-only check passes and the breakage surfaces much later as rejected
    # mail or a failed cert. Catch it here, blocking.
    if is_apex_host "$h" "$DOMAIN" && [[ -n "$_cn" ]]; then
      if [[ "$h" == "$DOMAIN" ]]; then
        bad "$h is a CNAME (-> $_cn) — must be an A record; a CNAME at the zone apex is invalid."
      else
        bad "$h is a CNAME (-> $_cn) — must be an A record; MX targets must not be CNAMEs or mail gets rejected."
      fi
      fails=$((fails+1)); continue
    fi
    _ip="$(resolve_ip "$h")"
    if grep -qx "$PUBLIC_IP" <<<"$_ip"; then
      if [[ -n "$_cn" ]]; then ok "CNAME $h -> $_cn -> $PUBLIC_IP"
      else                     ok "A     $h -> $PUBLIC_IP"; fi
    else
      bad "$h -> expected $PUBLIC_IP, got '$(paste -sd, - <<<"$_ip")'${_cn:+ (via CNAME $_cn)}"
      fails=$((fails+1))
    fi
  done

  if $MAIL_ON; then
    if qMX "$DOMAIN" | grep -qx "mail.$DOMAIN"; then ok "MX $DOMAIN -> mail.$DOMAIN"
    else bad "MX $DOMAIN -> expected mail.$DOMAIN, got '$(qMX "$DOMAIN" | paste -sd, -)'"; fails=$((fails+1)); fi
    if [[ "$MAIL_MODE" == direct ]]; then
      _ptr="$(qPTR "$PUBLIC_IP" || true)"
      if [[ "$_ptr" == "mail.$DOMAIN" ]]; then
        ok "PTR $PUBLIC_IP -> mail.$DOMAIN"; PTR_NOTE=""
      else
        warn "PTR $PUBLIC_IP -> '${_ptr:-<none>}' (advisory — not blocking)"
        PTR_NOTE="reverse DNS for ${PUBLIC_IP} is '${_ptr:-<none>}', not mail.${DOMAIN}. Set it at your VM provider — it costs deliverability, not startup."
      fi
    fi
  fi

  if (( fails == 0 )); then
    if [[ -n "$PTR_NOTE" ]]; then
      echo; printf '  %sAdvisory (not blocking):%s\n' "${c_warn}" "${c_end}"
      echo "    - ${PTR_NOTE}"
    fi
    step "All required records resolve. ${c_ok}DNS gate passed.${c_end}"
    exit 0
  fi
  printf '\n  %d required record(s) still failing.\n' "$fails"
  [[ -n "$ZONE_OUT" ]] && printf '  Zone snippet to paste: %s\n' "$ZONE_OUT"
  read -r -p "  Press Enter to re-check (Ctrl+C to abort)... " _ < /dev/tty
done
