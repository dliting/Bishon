#!/usr/bin/env bash
# scripts/docker/bishon-publish-image.sh
#
# Push the locally-built bishon-cuda:<ver> image to one or both registries.
# Manual trigger (no CI auto-push); run after bishon-build.sh whenever the
# image content changes (Dockerfile, entrypoint.sh, or apt/conda versions).
#
# Default: pushes to both ghcr.io and Aliyun.
#
# Usage:
#   bash bishon-publish-image.sh                       # push to both
#   bash bishon-publish-image.sh --registry ghcr       # only ghcr
#   bash bishon-publish-image.sh --registry aliyun     # only aliyun
#   bash bishon-publish-image.sh --vpc                 # aliyun via VPC endpoint
#   bash bishon-publish-image.sh --tag 2.2.0-rc1       # override VERSION file
#   bash bishon-publish-image.sh --no-latest           # don't tag :latest
#
# Auth (one-time per machine; persists in ~/.docker/config.json):
#   docker login ghcr.io -u dliting --password-stdin <<< "$GHCR_TOKEN"
#   docker login crpi-cpr1xsemy1pzwjoc.cn-beijing.personal.cr.aliyuncs.com \
#       -u hao_yufei@163.com
#
# Required env (when pushing to a registry for the first time on a machine):
#   GHCR_TOKEN     GitHub Personal Access Token with write:packages scope
#   ALIYUN_PWD     Aliyun Container Registry password (set in 控制台)
# Both are read from env only if docker login has not been done already.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Defaults
TAG=""
REGISTRY="both"          # both | ghcr | aliyun
ALIYUN_USE_VPC=false
TAG_LATEST=true

REGISTRY_GHCR="ghcr.io/dliting"
REGISTRY_ALIYUN="crpi-cpr1xsemy1pzwjoc.cn-beijing.personal.cr.aliyuncs.com/dliting"
REGISTRY_ALIYUN_VPC="crpi-cpr1xsemy1pzwjoc-vpc.cn-beijing.personal.cr.aliyuncs.com/dliting"
ALIYUN_USER="hao_yufei@163.com"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)        TAG="$2";     shift 2 ;;
        --registry)   REGISTRY="$2"; shift 2 ;;
        --vpc)        ALIYUN_USE_VPC=true; shift ;;
        --no-latest)  TAG_LATEST=false; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=publish-image
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# Read VERSION file if --tag not given
if [ -z "$TAG" ]; then
    VERSION_FILE="$REPO_ROOT/VERSION"
    [ -f "$VERSION_FILE" ] || die "VERSION file missing at $VERSION_FILE; pass --tag <ver>"
    TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
    [ -n "$TAG" ] || die "VERSION file is empty"
fi

LOCAL_IMAGE="bishon-cuda:$TAG"
log "looking for local image: $LOCAL_IMAGE"
docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || \
    die "$LOCAL_IMAGE not built. Run: bishon-build.sh"

# Choose aliyun endpoint
if $ALIYUN_USE_VPC; then
    REGISTRY_ALIYUN_URL="$REGISTRY_ALIYUN_VPC"
else
    REGISTRY_ALIYUN_URL="$REGISTRY_ALIYUN"
fi

# Login helper: only attempt login if credentials are provided AND not already
# authenticated. Docker stores auth in ~/.docker/config.json after first login.
ensure_login() {
    local registry_url="$1"
    local user="$2"
    local token_env="$3"

    # Already authenticated?
    if grep -q "$registry_url" ~/.docker/config.json 2>/dev/null; then
        log "already logged in to $registry_url"
        return 0
    fi

    local token="${!token_env:-}"
    if [ -z "$token" ]; then
        die "not logged in to $registry_url and \$$token_env not set. Run docker login manually first."
    fi
    echo "$token" | docker login "$registry_url" -u "$user" --password-stdin \
        || die "docker login failed for $registry_url"
}

push_to() {
    local registry_url="$1"
    local image_path="$registry_url/bishon-cuda"

    log "tagging $LOCAL_IMAGE → $image_path:$TAG"
    docker tag "$LOCAL_IMAGE" "$image_path:$TAG"

    if $TAG_LATEST; then
        docker tag "$LOCAL_IMAGE" "$image_path:latest"
        log "pushing $image_path:$TAG and :latest"
        docker push "$image_path:$TAG"
        docker push "$image_path:latest"
    else
        log "pushing $image_path:$TAG"
        docker push "$image_path:$TAG"
    fi
}

case "$REGISTRY" in
    both)
        ensure_login "$REGISTRY_GHCR" "dliting" "GHCR_TOKEN"
        ensure_login "$(echo "$REGISTRY_ALIYUN_URL" | sed 's|/dliting$||')" "$ALIYUN_USER" "ALIYUN_PWD"
        push_to "$REGISTRY_GHCR"
        push_to "$REGISTRY_ALIYUN_URL"
        ;;
    ghcr)
        ensure_login "$REGISTRY_GHCR" "dliting" "GHCR_TOKEN"
        push_to "$REGISTRY_GHCR"
        ;;
    aliyun)
        ensure_login "$(echo "$REGISTRY_ALIYUN_URL" | sed 's|/dliting$||')" "$ALIYUN_USER" "ALIYUN_PWD"
        push_to "$REGISTRY_ALIYUN_URL"
        ;;
    *)
        die "unknown --registry: $REGISTRY (use both|ghcr|aliyun)"
        ;;
esac

log "done."
docker images --format "{{.Repository}}:{{.Tag}}  {{.Size}}" | grep bishon-cuda | head -5
