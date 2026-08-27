#!/usr/bin/env bash
# =============================================================================
# after-e- — prereqs.sh   (run FIRST)   [SECOND DRAFT]
# =============================================================================
# Debian-family only. Idempotent. Installs the host tooling the other scripts
# depend on: Docker CE + compose plugin, cron (acme.sh renewals need it), git +
# socat (cert-http standalone), dig, swaks (+TLS), curl, openssl, jq.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root (installs system packages)."

# --- detect distro -----------------------------------------------------------
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release."
. /etc/os-release
DIST_ID="${ID:-}"; DIST_LIKE="${ID_LIKE:-}"; CODENAME="${VERSION_CODENAME:-}"
case "$DIST_ID" in
  debian|ubuntu|raspbian) DOCKER_DISTRO="$DIST_ID" ;;
  *) if [[ "$DIST_LIKE" == *debian* ]]; then
       warn "distro '$DIST_ID' not directly supported but Debian-like; using Debian repo."
       DOCKER_DISTRO="debian"
     else die "Debian-family only (got ID='$DIST_ID')."; fi ;;
esac
[[ -n "$CODENAME" ]] || { CODENAME="bookworm"; warn "no VERSION_CODENAME; assuming '$CODENAME'."; }
ok "detected ${PRETTY_NAME:-$DIST_ID} ($CODENAME, $(dpkg --print-architecture))"

# =============================================================================
# host preflight — architecture + memory (before any questions)
# =============================================================================
# Two "you're stepping over a real line" gates. Both STOP by default (an override
# that needs no action isn't a conscious choice) but hand over an env skip for
# unattended runs. The RAM advisories in the middle bands only steer a choice, so
# they print and move on.
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) : ;;                              # supported
  *)
    if [[ "${AFTERE_ALLOW_ARCH:-0}" == 1 ]]; then
      warn "architecture $ARCH is unsupported; continuing (AFTERE_ALLOW_ARCH=1)."
    else
      echo
      echo "  After-e- is only tested on x86; other architectures such as ARM may work,"
      echo "  but testing is only done on x86. You can continue at your own risk."
      echo "    1) Continue on ARM anyway"
      echo "    2) Stop"
      read -r -p "  choice [1-2]: " _arch < /dev/tty
      [[ "$_arch" == 1 ]] || die "stopped — not an x86 machine. (Set AFTERE_ALLOW_ARCH=1 to skip this prompt.)"
      warn "continuing on unsupported architecture ($ARCH) at your request."
    fi ;;
esac

MEM_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_GB=$(( (MEM_KB + 524288) / 1048576 ))        # round to nearest GiB for display
if (( MEM_KB > 0 )); then
  if (( MEM_KB < 3800000 )); then                # under ~4 GB — override gate
    if [[ "${AFTERE_ALLOW_LOWRAM:-0}" == 1 ]]; then
      warn "low memory (${MEM_GB} GB); continuing (AFTERE_ALLOW_LOWRAM=1)."
    else
      echo
      echo "  This machine has about ${MEM_GB} GB of RAM. after-e- runs several database"
      echo "  instances and is very likely to hit stability problems with this little memory."
      echo "  We won't stop you, but you should seriously consider adding RAM to this VM or VPS"
      echo "  before going further."
      echo "    1) Install anyway"
      echo "    2) Stop"
      read -r -p "  choice [1-2]: " _ram < /dev/tty
      [[ "$_ram" == 1 ]] || die "stopped — add RAM and re-run. (Set AFTERE_ALLOW_LOWRAM=1 to skip this prompt.)"
      warn "continuing with low memory (${MEM_GB} GB) at your request."
    fi
  elif (( MEM_KB < 7500000 )); then              # ~4–8 GB — advisory
    step "Memory"
    echo "  ${MEM_GB} GB of RAM. Enough for a good setup, but Immich (photos) is the"
    echo "  memory-hungry piece — the “/e/Cloud Server Replacement” or “File Sync Only” tiers leave it out."
  elif (( MEM_KB < 15000000 )); then             # ~8–16 GB — advisory
    step "Memory"
    echo "  ${MEM_GB} GB of RAM. Plenty for the full Kitchen Sink — just go easy on the heavier"
    echo "  post-install extras."
  else                                           # 16 GB+ — advisory
    step "Memory"
    echo "  ${MEM_GB} GB of RAM. Room for everything — install whatever you like."
  fi
fi


# --- base packages -----------------------------------------------------------
step "Installing base tooling"
apt-get update -qq
DNS_PKG="bind9-dnsutils"; apt-cache show bind9-dnsutils >/dev/null 2>&1 || DNS_PKG="dnsutils"
# gettext-base -> envsubst (init.sh and stalwart-provision.sh hard-require it;
# masked on Azure Ubuntu images, which ship it, but absent on minimal Debian).
# xz-utils -> tar can decompress the stalwart-cli .tar.xz release below.
BASE_PKGS=( ca-certificates curl gnupg openssl jq swaks libnet-ssleay-perl "$DNS_PKG" cron git socat gettext-base xz-utils )
TO_INSTALL=()
for p in "${BASE_PKGS[@]}"; do
  if dpkg -s "$p" >/dev/null 2>&1; then ok "$p already installed"; else TO_INSTALL+=("$p"); fi
done
if (( ${#TO_INSTALL[@]} )); then
  # --no-install-recommends: cron Recommends default-mta (= exim4-daemon-light on
  # Debian), which would land an MTA on :25 that Stalwart then has to fight. All
  # our real needs are explicit in BASE_PKGS, so nothing we use rides in on a
  # recommend (libnet-ssleay-perl, the one that could, is listed outright).
  apt-get install -y -qq --no-install-recommends "${TO_INSTALL[@]}" || die "apt failed installing: ${TO_INSTALL[*]}"
  ok "installed: ${TO_INSTALL[*]}"
fi
systemctl enable --now cron >/dev/null 2>&1 || warn "could not enable cron via systemd — acme.sh renewals need it."

# --- Docker CE + compose plugin ---------------------------------------------
step "Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "docker + compose plugin already present ($(docker --version | awk '{print $3}' | tr -d ,))"
else
  warn "installing Docker CE from Docker's official apt repo."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc \
      || die "could not fetch Docker GPG key."
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    || die "Docker install failed. See https://docs.docker.com/engine/install/debian/"
  systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable docker via systemd."
  ok "Docker CE + compose plugin installed"
fi

# --- stalwart-cli (NOT in the docker image in v0.16 — host-installed) --------
# stalwart-provision.sh drives stalwart-cli to configure Stalwart without the
# browser wizard. The CLI lives in its OWN repo (stalwartlabs/cli), separate from
# the server (stalwartlabs/stalwart), and ships as a per-platform .tar.xz.
#
# PINNED: the CLI is versioned independently of the server (server is 0.16.x),
# but it is schema-coupled to it — the provisioning plan templates were captured
# by `stalwart-cli snapshot` against this CLI/server pair. Treat image tag + CLI
# version + plan templates as one unit; bump them together (and re-snapshot) in
# a future update.sh rather than floating any one of them.
SC_VERSION="v1.0.12"
if command -v stalwart-cli >/dev/null 2>&1; then
  ok "stalwart-cli present ($(stalwart-cli --version 2>/dev/null | head -n1 || echo installed))"
else
  step "Installing stalwart-cli ${SC_VERSION}"
  case "$(uname -m)" in
    x86_64|amd64)  SC_ARCH="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) SC_ARCH="aarch64-unknown-linux-gnu" ;;   # unsupported path; best-effort
    *) SC_ARCH="" ;;
  esac
  if [[ -z "$SC_ARCH" ]]; then
    warn "unknown arch $(uname -m) — install stalwart-cli manually from https://github.com/stalwartlabs/cli/releases"
  else
    SC_URL="https://github.com/stalwartlabs/cli/releases/download/${SC_VERSION}/stalwart-cli-${SC_ARCH}.tar.xz"
    SC_TMP="$(mktemp -d)"
    if curl -fsSL "$SC_URL" -o "$SC_TMP/stalwart-cli.tar.xz" 2>/dev/null; then
      # tar xf auto-detects xz (needs the xz binary from xz-utils, installed above).
      if tar xf "$SC_TMP/stalwart-cli.tar.xz" -C "$SC_TMP" 2>/dev/null; then
        # don't assume the binary's path inside the archive — find it.
        SC_BIN="$(find "$SC_TMP" -type f -name stalwart-cli 2>/dev/null | head -n1 || true)"
        if [[ -n "$SC_BIN" ]] && install -m 0755 "$SC_BIN" /usr/local/bin/stalwart-cli 2>/dev/null; then
          ok "stalwart-cli ${SC_VERSION} installed to /usr/local/bin"; rm -rf "$SC_TMP"
        else
          warn "extracted stalwart-cli but couldn't find/install the binary — look in $SC_TMP"
        fi
      else
        warn "downloaded stalwart-cli but couldn't extract it — is xz-utils installed? ($SC_TMP kept)"
      fi
    else
      warn "could not download stalwart-cli ${SC_VERSION} from:"
      warn "  $SC_URL"
      warn "  install it manually from https://github.com/stalwartlabs/cli/releases"
      rm -rf "$SC_TMP"
    fi
  fi
fi

# --- verify (same tools init.sh / cert-http.sh look for) --------------------
step "Verifying"
fail=0
check() { if command -v "$1" >/dev/null 2>&1; then ok "$1"; else bad "$1 MISSING"; fail=1; fi; }
check docker; check dig; check swaks; check curl; check openssl; check jq; check git; check socat; check envsubst
docker compose version >/dev/null 2>&1 && ok "docker compose plugin" || { bad "compose plugin MISSING"; fail=1; }
command -v crontab >/dev/null 2>&1 && ok "cron/crontab" || { bad "crontab MISSING (acme.sh needs it)"; fail=1; }
if perl -MNet::SSLeay -e1 >/dev/null 2>&1; then ok "swaks TLS (Net::SSLeay)"; else bad "Net::SSLeay MISSING"; fail=1; fi
(( fail )) && die "one or more prerequisites are missing (see above)."

step "Prerequisites ready — next: bash init.sh"
ok "done"
