#!/usr/bin/env bash
# scripts/docker/bishon-deploy-docker.sh
#
# L2 deployment module: Docker mode. Handles online (pull), offline (load),
# and existing-image scenarios. Calls bishon-install.sh + bishon-start.sh.
#
# Usually invoked by bishon-deploy.sh (the wizard). Can also be called
# directly when the user knows they want Docker mode.
#
# Usage:
#   bash bishon-deploy-docker.sh --host-dir <dir> --release <tar> \
#       (--image <tar> | --pull [--registry ghcr|aliyun] | --image-source existing) \
#       [--models <tar>] [--tag <ver>] [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# All args are forwarded to bishon-install.sh, except --dry-run and --start
# which are handled here.
HOST_DIR=""
RELEASE_TAR=""
DRY_RUN=false
START_AFTER=true
INSTALL_ARGS=()
MODELS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --no-start)     START_AFTER=false; shift ;;
        --help|-h)
            cat <<'EOF'
bishon-deploy-docker.sh — L2 Docker deployment module.

Orchestrates bishon-install.sh + bishon-start.sh for any Docker mode
(online pull, offline load, or already-existing image). All flags except
the two listed below are forwarded to bishon-install.sh.

USAGE
  bash bishon-deploy-docker.sh --host-dir <dir> --release <tar> \
      (--image <tar> | --pull [--registry ghcr|aliyun] | --image-source existing) \
      [--models <tar>] [--tag <ver>] [--accelerator cuda]

FLAGS
  --dry-run        Print the install.sh + start.sh invocation plan, do not run.
  --no-start       Stop after install.sh; skip start.sh (useful for staging).
  All other flags are forwarded to bishon-install.sh. See:
    bishon-install.sh --help

EXAMPLES
  Online pull from ghcr.io:
    bash bishon-deploy-docker.sh --host-dir /var/lib/bishon \
        --release r.tar.gz --pull --registry ghcr

  Offline load:
    bash bishon-deploy-docker.sh --host-dir /var/lib/bishon \
        --release r.tar.gz --image bishon-cuda-image-2.2.0.tar

  Dry-run to see what would be invoked:
    bash bishon-deploy-docker.sh --host-dir /tmp/x --release r.tar.gz --pull --dry-run
EOF
            exit 0 ;;
        *) INSTALL_ARGS+=("$1"); shift ;;
    esac
done

export BISHON_LOG_TAG=deploy-docker
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# Pull host-dir out of INSTALL_ARGS for our own use (logging, start.sh call).
for ((i=0; i<${#INSTALL_ARGS[@]}; i++)); do
    if [ "${INSTALL_ARGS[$i]}" = "--host-dir" ] && [ $((i+1)) -lt ${#INSTALL_ARGS[@]} ]; then
        HOST_DIR="${INSTALL_ARGS[$((i+1))]}"
    fi
    if [ "${INSTALL_ARGS[$i]}" = "--release" ] && [ $((i+1)) -lt ${#INSTALL_ARGS[@]} ]; then
        RELEASE_TAR="${INSTALL_ARGS[$((i+1))]}"
    fi
done
[ -n "$HOST_DIR" ]   || die "--host-dir required"
[ -n "$RELEASE_TAR" ] || die "--release required"

if $DRY_RUN; then
    log "=== DRY RUN: docker deployment ==="
    log "host-dir: $HOST_DIR"
    log "release:  $RELEASE_TAR"
    log "would call: bishon-install.sh ${INSTALL_ARGS[*]}"
    if $START_AFTER; then
        log "would call: bishon-start.sh --host-dir $HOST_DIR"
    fi
    exit 0
fi

log "=== Step 1/2: install ==="
bash "$(dirname "$0")/bishon-install.sh" "${INSTALL_ARGS[@]}"

if $START_AFTER; then
    log "=== Step 2/2: start ==="
    bash "$(dirname "$0")/bishon-start.sh" --host-dir "$HOST_DIR"
fi

log "=== Docker deployment complete ==="
log "Service: http://localhost:8777/bishon/"
log "Health:  http://localhost:8777/api/health"
log "Stop:    bash $(dirname "$0")/bishon-stop.sh --host-dir $HOST_DIR"
