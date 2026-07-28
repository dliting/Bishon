#!/usr/bin/env bash
# bishon-uninstall.sh — remove the container and image. Data is preserved by
# default.
#
# Usage:
#   bash bishon-uninstall.sh --host-dir <dir> [--purge-data]
#
# Without --purge-data:
#   - Stops + removes the container
#   - Removes the image (read from .image-tag)
#   - Keeps <host-dir>/ entirely (env, code, models, BISHON_DB, logs, .env)
#
# With --purge-data:
#   - Same as above, then REFUSES to auto-rm-rf <host-dir>. The operator must
#     run `rm -rf <host-dir>` manually. This is intentional: a script that
#     takes a dir and silently removes gigabytes is too dangerous.

set -euo pipefail

HOST_DIR=""
PURGE_DATA=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir)   HOST_DIR="$2"; shift 2 ;;
        --purge-data) PURGE_DATA=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 --host-dir <dir> [--purge-data]

Without --purge-data: removes container + image, keeps all data.
With --purge-data:    also removes container + image, then refuses to auto-rm-rf
                      <host-dir> — operator must run rm -rf manually.
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
[ -n "$HOST_DIR" ] || { echo "usage: $0 --host-dir <dir> [--purge-data]" >&2; exit 1; }

HOST_DIR="$(readlink -f "$HOST_DIR")"
log() { echo "[uninstall] $*"; }

log "stopping + removing container 'bishon' (if any)"
if docker ps -a --format '{{.Names}}' | grep -qx bishon; then
    docker rm -f bishon >/dev/null 2>&1 || true
fi

if [ -f "$HOST_DIR/.image-tag" ]; then
    IMG="$(cat "$HOST_DIR/.image-tag")"
    log "removing image $IMG (if no other container is using it)"
    docker rmi "$IMG" 2>/dev/null || log "WARN: image $IMG not removed (still in use?)"
else
    log "no .image-tag found — skipping image removal"
fi

if $PURGE_DATA; then
    cat >&2 <<EOF
[uninstall] --purge-data given. For safety, this script will NOT auto-delete
            $HOST_DIR. If you really mean it, run manually:

              rm -rf "$HOST_DIR"
EOF
    exit 1
else
    log "data preserved at $HOST_DIR. Re-run with --purge-data to be reminded"
    log "how to delete it manually."
fi
