#!/usr/bin/env bash
# bishon-build.sh — build the Bishon V2 container image.
#
# Usage:
#   bash scripts/docker/bishon-build.sh --version <ver> [--accelerator cuda]
#
# Output:
#   Image tagged `bishon-<accelerator>:<version>`, e.g. bishon-cuda:2.1.0.
#
# This script is for DEVELOPERS. It requires:
#   - Docker daemon running locally with network access (for apt + miniconda).
#   - The repo checked out at <repo-root>/docker/Dockerfile.<accelerator>.
#
# For fully offline image builds, pre-download Miniconda3-latest-Linux-x86_64.sh
# into docker/ and change the Dockerfile's wget line to COPY — out of scope here.

set -euo pipefail

VERSION=""
ACC="cuda"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     VERSION="$2"; shift 2 ;;
        --accelerator) ACC="$2";    shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 --version <ver> [--accelerator cuda|ascend]
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$VERSION" ] || { echo "usage: $0 --version <ver>" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCKERFILE="$REPO_ROOT/docker/Dockerfile.$ACC"

export BISHON_LOG_TAG=build
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

[ -f "$DOCKERFILE" ] || {
    die "$DOCKERFILE not found."
    [ "$ACC" = "ascend" ] && \
        log "Ascend image is a placeholder in this round; not implemented yet."
}

IMAGE="bishon-$ACC:$VERSION"
log "Building $IMAGE from $DOCKERFILE ..."
docker build \
    -t "$IMAGE" \
    -f "$DOCKERFILE" \
    "$REPO_ROOT/docker"

# Tag as latest so CI/automation scripts can always pull :latest
# without parsing version numbers. bishon-install.sh still pins to a
# specific version via .image-tag; :latest is for human/CI convenience.
docker tag "$IMAGE" "bishon-$ACC:latest"

log "Built $IMAGE (+ tagged bishon-$ACC:latest)"
SIZE_BYTES="$(docker image inspect "$IMAGE" --format '{{.Size}}')"
SIZE_GIB="$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.1f", b/1073741824}')"
log "Size: ${SIZE_BYTES} bytes (~${SIZE_GIB} GiB)"
