#!/usr/bin/env bash
# deploy.sh — Bishon V2 部署入口。交互式向导或非交互式 CLI。
#
# 三种模式:
#   docker-online   从 ghcr.io / 阿里云拉镜像
#   docker-offline  从本地 tar 加载镜像
#   bare-metal      无 Docker，直接 uvicorn
#
# 用法:
#   bash deploy.sh                              # 交互向导
#   bash deploy.sh --non-interactive [flags...] # CI / 批量

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Variables ---------------------------------------------------------------
NON_INTERACTIVE=false
DRY_RUN=false
START_AFTER=true
MODE=""
HOST_DIR=""
RELEASE_TAR=""
IMAGE_TAR=""
IMAGE_SOURCE=""
REGISTRY="ghcr"
TAG=""
MODELS_SOURCE=""
MODELS_TAR=""
MODELS_DIR=""
SOURCE_DIR=""
CONDA_ENV=""
INSTALL_DEPS=false
NATIVE_WINDOWS=false
LOAD_CONFIG=""
SAVE_CONFIG=true
BUNDLE_DIR=""

# --- Arg parsing -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        --no-start)        START_AFTER=false; shift ;;
        --mode)            MODE="$2"; shift 2 ;;
        --host-dir)        HOST_DIR="$2"; shift 2 ;;
        --release)         RELEASE_TAR="$2"; shift 2 ;;
        --image)           IMAGE_TAR="$2"; IMAGE_SOURCE="load"; shift 2 ;;
        --pull)            IMAGE_SOURCE="pull"; shift ;;
        --image-source)    IMAGE_SOURCE="$2"; shift 2 ;;
        --registry)        REGISTRY="$2"; shift 2 ;;
        --tag)             TAG="$2"; shift 2 ;;
        --models-source)   MODELS_SOURCE="$2"; shift 2 ;;
        --models)          MODELS_TAR="$2"; MODELS_SOURCE="tarball"; shift 2 ;;
        --models-dir)      MODELS_DIR="$2"; MODELS_SOURCE="directory"; shift 2 ;;
        --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
        --conda-env)       CONDA_ENV="$2"; shift 2 ;;
        --install-deps)    INSTALL_DEPS=true; shift ;;
        --native-windows)  NATIVE_WINDOWS=true; shift ;;
        --load-config)     LOAD_CONFIG="$2"; shift 2 ;;
        --no-save-config)  SAVE_CONFIG=false; shift ;;
        --bundle-dir)      BUNDLE_DIR="$2"; shift 2 ;;
        --help|-h)         sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=deploy
source "$SCRIPT_DIR/scripts/common/utils.sh"
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# --- Platform detection ------------------------------------------------------
detect_platform() {
    case "$(uname -s)" in
        Linux*)
            grep -qi microsoft /proc/version 2>/dev/null && echo "wsl" || echo "linux" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        Darwin) echo "macos" ;;
        *) echo "unknown" ;;
    esac
}
PLATFORM="$(detect_platform)"
log "platform: $PLATFORM"

if [ "$PLATFORM" = "windows" ] && ! $NATIVE_WINDOWS; then
    cat >&2 <<EOF
[deploy] Native Windows detected. Bishon V2 targets WSL2.
         Open WSL2 terminal and run: bash deploy.sh
         --native-windows to force (unsupported).
EOF
    exit 1
fi

# --- Load saved config -------------------------------------------------------
if [ -z "$LOAD_CONFIG" ] && [ -n "$HOST_DIR" ] && [ -f "$HOST_DIR/deploy.conf" ]; then
    LOAD_CONFIG="$HOST_DIR/deploy.conf"
fi
if [ -n "$LOAD_CONFIG" ] && [ -f "$LOAD_CONFIG" ]; then
    log "loading saved config from $LOAD_CONFIG"
    source "$LOAD_CONFIG"
fi

# --- Preflight (informational) -----------------------------------------------
VERSION_FOR_PF="${TAG:-}"
if [ -z "$VERSION_FOR_PF" ]; then
    for vf in "$SCRIPT_DIR/VERSION" "$SCRIPT_DIR/../VERSION" "$PWD/VERSION"; do
        [ -f "$vf" ] && VERSION_FOR_PF="$(tr -d '[:space:]' < "$vf")" && break
    done
fi
MODE_FOR_PF="${MODE:-release}"
log "=== preflight (informational) ==="
PF_ARGS=(--mode "$MODE_FOR_PF")
[ -n "$VERSION_FOR_PF" ] && PF_ARGS+=(--version "$VERSION_FOR_PF")
bash "$SCRIPT_DIR/scripts/common/preflight.sh" "${PF_ARGS[@]}" 2>&1 | sed 's/^/  /' || true

# --- Wizard (sets MODE, HOST_DIR, RELEASE_TAR, etc.) -------------------------
source "$SCRIPT_DIR/scripts/common/wizard.sh"

# --- Save config (non dry-run) -----------------------------------------------
if ! $DRY_RUN && $SAVE_CONFIG && [ -n "$HOST_DIR" ]; then
    CONF="$HOST_DIR/deploy.conf"
    cat > "$CONF" <<EOCONF
# Auto-saved by deploy.sh
MODE="$MODE"
HOST_DIR="$HOST_DIR"
RELEASE_TAR="$RELEASE_TAR"
IMAGE_TAR="$IMAGE_TAR"
IMAGE_SOURCE="$IMAGE_SOURCE"
REGISTRY="$REGISTRY"
TAG="$TAG"
MODELS_SOURCE="$MODELS_SOURCE"
MODELS_TAR="$MODELS_TAR"
MODELS_DIR="$MODELS_DIR"
SOURCE_DIR="$SOURCE_DIR"
CONDA_ENV="$CONDA_ENV"
INSTALL_DEPS="$INSTALL_DEPS"
EOCONF
    log "config saved to $CONF"
fi

# --- Dispatch ----------------------------------------------------------------
if $DRY_RUN; then
    log "(dry-run: not executing)"
    exit 0
fi

# Handle models directory symlink
if [ "$MODELS_SOURCE" = "directory" ] && [ -d "$MODELS_DIR" ]; then
    case "$MODE" in
        docker-*)
            rm -f "$HOST_DIR/models" 2>/dev/null || true
            ln -sfn "$MODELS_DIR" "$HOST_DIR/models"
            log "linked $HOST_DIR/models → $MODELS_DIR" ;;
        bare-metal)
            rm -f "$SOURCE_DIR/models" 2>/dev/null || true
            ln -sfn "$MODELS_DIR" "$SOURCE_DIR/models"
            log "linked $SOURCE_DIR/models → $MODELS_DIR" ;;
    esac
fi

case "$MODE" in
    docker-online|docker-offline)
        INSTALL_ARGS=(--host-dir "$HOST_DIR" --release "$RELEASE_TAR")
        case "$IMAGE_SOURCE" in
            pull)     INSTALL_ARGS+=(--pull --registry "$REGISTRY") ;;
            load)     INSTALL_ARGS+=(--image "$IMAGE_TAR") ;;
            existing) INSTALL_ARGS+=(--image-source existing) ;;
        esac
        [ -n "$TAG" ] && INSTALL_ARGS+=(--tag "$TAG")
        if [ "$MODELS_SOURCE" = "tarball" ]; then
            INSTALL_ARGS+=(--models "$MODELS_TAR")
        elif [ "$MODELS_SOURCE" = "directory" ]; then
            INSTALL_ARGS+=(--models-dir "$MODELS_DIR")
        fi
        bash "$SCRIPT_DIR/scripts/docker/install.sh" "${INSTALL_ARGS[@]}"
        if $START_AFTER; then
            bash "$SCRIPT_DIR/scripts/docker/start.sh" --host-dir "$HOST_DIR"
        fi
        ;;
    bare-metal)
        bash "$SCRIPT_DIR/scripts/common/preflight.sh" --mode bare-metal || true
        if $INSTALL_DEPS; then
            (cd "$SOURCE_DIR" && pip install -r requirements.txt)
        fi
        case "$MODELS_SOURCE" in
            online)  bash "$SCRIPT_DIR/scripts/common/download-models.sh" --target "$SOURCE_DIR/models" ;;
            tarball) bash "$SCRIPT_DIR/scripts/common/download-models.sh" --target "$SOURCE_DIR/models" --offline "$MODELS_TAR" ;;
        esac
        if $START_AFTER; then
            bash "$SCRIPT_DIR/scripts/bare-metal/start.sh" --source-dir "$SOURCE_DIR"
        fi
        ;;
    *) die "unknown mode: $MODE" ;;
esac
