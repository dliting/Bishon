#!/usr/bin/env bash
# stop.sh — stop and remove the Bishon V2 container.
#
# Usage:
#   bash stop.sh --host-dir <dir>
#
# Idempotent: no-op if no container exists. Image is preserved (use
# uninstall.sh to remove the image).

set -euo pipefail

HOST_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir) HOST_DIR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
stop.sh — Stop and remove the Bishon V2 container.

Idempotent: no-op if no container exists. Image and <host-dir> data are
preserved. Use uninstall.sh to remove the image or data.

USAGE
  bash $0 --host-dir <dir>

FLAGS
  --host-dir <dir>   The directory passed to install.sh.

EXAMPLES
  bash $0 --host-dir /var/lib/bishon
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
[ -n "$HOST_DIR" ] || { echo "usage: $0 --host-dir <dir>" >&2; exit 1; }

export BISHON_LOG_TAG=stop
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
log() { bishon_log "$@"; }

if docker ps -a --format '{{.Names}}' | grep -qx bishon; then
    log "removing container 'bishon'"
    docker stop bishon >/dev/null 2>&1 || true
    docker rm   bishon >/dev/null 2>&1 || true
else
    log "no container named 'bishon' — nothing to do"
fi
