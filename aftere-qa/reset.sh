#!/usr/bin/env bash
# =============================================================================
# after/e/ — reset.sh   (QA convenience: return to a clean pre-install state)
# =============================================================================
# Stops + removes containers/networks, deletes config + data (bind mounts) AND
# the root .env / answers.env (secrets + resume cache live OUTSIDE config/).
# Keeps pulled Docker images cached so the next ./init.sh is fast.
# DESTRUCTIVE and not reversible — everything the stack stored is erased.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[[ $EUID -eq 0 ]] || die "run as root."

# read paths BEFORE we delete the .env that holds them
CONFIG_PATH="$(getcfg AFTERE_CONFIG || echo /mnt/aftere/config)"
DATA_PATH="$(getcfg AFTERE_DATA   || echo /mnt/aftere/data)"

echo "  This will STOP all after/e/ containers and permanently DELETE:"
echo "    - ${CONFIG_PATH}   (all state: databases, certs, blueprints, acme)"
echo "    - ${DATA_PATH}   (bulk: nextcloud / immich / stalwart data)"
echo "    - ${ENV_FILE}   (generated secrets)"
echo "    - ${ANSWER_FILE}   (questionnaire resume cache)"
echo "  Docker IMAGES are KEPT (fast re-run). This cannot be undone."
read -r -p "  Type 'reset' to proceed: " c < /dev/tty
[[ "$c" == "reset" ]] || die "aborted — nothing changed."

cd "$REPO_BASE"
step "Stopping containers"
docker compose down --remove-orphans 2>/dev/null && ok "containers/networks removed" || warn "compose down had nothing to do."

step "Deleting state"
rm -rf "$CONFIG_PATH" "$DATA_PATH"
rm -f  "$ENV_FILE" "$ANSWER_FILE"
ok "state, secrets, and resume cache erased"

step "Reset complete"
echo "  Clean slate (images retained). Next: ./init.sh"
