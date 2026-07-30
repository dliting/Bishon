#!/usr/bin/env bash
# start.sh — start the Bishon V2 container on an installed host.
#
# Usage:
#   bash start.sh --host-dir <dir>
#
# Reads the installed image tag from $HOST_DIR/.image-tag (written by install).
# Restarts cleanly if a same-name container already exists.

set -euo pipefail

HOST_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir) HOST_DIR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
start.sh — Start the Bishon V2 container.

Reads .image-tag and .accelerator from <host-dir>, runs the container with
-v <host-dir>:/opt/bishon-data + --env-file <host-dir>/.env + GPU flags,
then polls /api/health up to 180s (cold-start budget for model loading).

USAGE
  bash $0 --host-dir <dir>

FLAGS
  --host-dir <dir>   Directory created by install.sh. Must contain
                     .image-tag, .accelerator (optional, defaults to cuda),
                     and .env.

EXAMPLES
  bash $0 --host-dir /var/lib/bishon
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$HOST_DIR" ] || { echo "usage: $0 --host-dir <dir>" >&2; exit 1; }

export BISHON_LOG_TAG=start
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

HOST_DIR="$(readlink -f "$HOST_DIR")"
[ -f "$HOST_DIR/.image-tag" ] || die "$HOST_DIR/.image-tag missing. Run install.sh first."

IMAGE="$(cat "$HOST_DIR/.image-tag")"
ACC="$(cat "$HOST_DIR/.accelerator" 2>/dev/null || echo cuda)"

command -v docker >/dev/null || die "docker not found on PATH"
command -v curl >/dev/null   || die "curl not found on PATH"

[ -f "$HOST_DIR/.env" ] || die "$HOST_DIR/.env missing. Run install.sh first."

# --- 1. Remove any same-name container ---------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx bishon; then
    log "removing existing container 'bishon'"
    docker rm -f bishon >/dev/null
fi

# --- 2. Compose run flags ----------------------------------------------------
GPU_FLAGS=()
case "$ACC" in
    cuda)
        # Fail fast if the nvidia container runtime isn't registered. Running
        # `docker run --gpus all` without it produces a confusing daemon error
        # that surfaces only after the 180s health-check timeout below.
        if ! docker info 2>/dev/null | grep -qE 'Runtimes:.*nvidia|Default Runtime: nvidia'; then
            cat >&2 <<EOF
[start] FATAL: NVIDIA Container Toolkit not registered with Docker.
       Install it first:
         sudo apt install -y nvidia-container-toolkit
         sudo nvidia-ctk runtime configure --runtime=docker
         sudo systemctl restart docker
       Verify with: docker info | grep -i runtime
EOF
            exit 1
        fi
        GPU_FLAGS=(--gpus all)
        ;;
    ascend)
        # Placeholder: real flags will be --device /dev/davinci0 etc.
        die "accelerator=ascend not implemented in this round"
        ;;
    *)
        die "unknown accelerator '$ACC' in $HOST_DIR/.accelerator"
        ;;
esac

# --- 3. Run ------------------------------------------------------------------
log "starting container 'bishon' (image=$IMAGE, acc=$ACC)"
docker run -d \
    --name bishon \
    "${GPU_FLAGS[@]}" \
    -p 8777:8777 \
    --env-file "$HOST_DIR/.env" \
    -v "$HOST_DIR:/opt/bishon-data" \
    --restart unless-stopped \
    "$IMAGE" \
    >/dev/null
log "container started"

# --- 4. Health check (避坑指南 #5) -------------------------------------------
# Cold start is heavy: torch/paddle/transformers/faiss first imports ~20-40s,
# then init_cfg() loads Rerank + PaddleOCR models ~30-60s. Poll 180s before
# declaring failure.
log "waiting for /api/health (up to 180s) ..."
for i in $(seq 1 90); do
    if curl -fsS http://localhost:8777/api/health >/dev/null 2>&1; then
        log "Bishon is up (after $((i*2))s)"
        # Static-asset check (避坑指南 #4 陷阱 2). A missing dist/ would let
        # the API come up while the UI is broken — fail loudly rather than
        # discover at user-complaint time.
        http_code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8777/bishon/ || true)"
        if [ "$http_code" != "200" ]; then
            dist_index="$HOST_DIR/bishon/bishon_kernel/bishon_server/dist/bishon/index.html"
            if [ ! -f "$dist_index" ]; then
                die "/bishon/ returned HTTP $http_code and $dist_index is missing. Rebuild frontend (cd front_end && npm ci && npm run build), copy front_end/dist to bishon_kernel/bishon_server/, then re-run make-release.sh + publish.sh."
            fi
            die "/bishon/ returned HTTP $http_code despite $dist_index existing. Check container logs: docker logs bishon"
        fi
        log "UI assets served at /bishon/ (200 OK)"
        exit 0
    fi
    sleep 2
done

# --- 5. Failure diagnostics --------------------------------------------------
die "Bishon did not become healthy within 180s. Last 50 log lines:
$(docker logs bishon 2>&1 | tail -50)"
