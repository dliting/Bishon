#!/usr/bin/env bash
# scripts/docker/bishon-deploy.sh
#
# L3 wizard: top-level deployment orchestrator. Asks the user (or accepts
# CLI flags / saved config) which deployment mode to use, then dispatches
# to the appropriate L2 module.
#
# Three modes:
#   docker-online   Pull image from ghcr.io or Aliyun, run in Docker.
#   docker-offline  Load image from local tar, run in Docker.
#   bare-metal      No Docker; run uvicorn directly with the bishon conda env.
#
# Usage (interactive):
#   bash bishon-deploy.sh
#
# Usage (non-interactive):
#   bash bishon-deploy.sh --non-interactive \
#       --mode docker-online --host-dir /var/lib/bishon \
#       --release /path/to/release.tar.gz \
#       --registry aliyun --models-source online
#
# Flags / config file:
#   Every interactive question has a corresponding flag. Answers are also
#   persisted to <host-dir>/deploy.conf after a successful run; subsequent
#   invocations read it as defaults.
#
# Detection:
#   - Running on native Windows (MSYS / Cygwin / cmd) → warn, suggest WSL2.
#     --native-windows forces continuation.
#   - Running in WSL or Linux → proceed normally.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Wizard state (filled by args or prompts)
NON_INTERACTIVE=false
DRY_RUN=false
MODE=""                # docker-online | docker-offline | bare-metal
HOST_DIR=""
RELEASE_TAR=""
IMAGE_TAR=""
IMAGE_SOURCE=""        # pull | load | existing
REGISTRY="ghcr"
TAG=""
MODELS_SOURCE=""       # online | tarball | skip
MODELS_TAR=""
SOURCE_DIR=""
CONDA_ENV=""
INSTALL_DEPS=false
NATIVE_WINDOWS=false
LOAD_CONFIG=""
SAVE_CONFIG=true

# --- arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
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
        --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
        --conda-env)       CONDA_ENV="$2"; shift 2 ;;
        --install-deps)    INSTALL_DEPS=true; shift ;;
        --native-windows)  NATIVE_WINDOWS=true; shift ;;
        --load-config)     LOAD_CONFIG="$2"; shift 2 ;;
        --no-save-config)  SAVE_CONFIG=false; shift ;;
        --help|-h)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=deploy
source "$SCRIPT_DIR/lib/common.sh"
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# --- helpers ----------------------------------------------------------------
ask() {
    # ask "prompt" "default" → prints user input or default on Enter.
    local prompt="$1" default="${2:-}" reply
    if $NON_INTERACTIVE; then
        echo "$default"
        return
    fi
    if [ -n "$default" ]; then
        read -rp "$prompt [$default] " reply
        echo "${reply:-$default}"
    else
        read -rp "$prompt " reply
        echo "$reply"
    fi
}

ask_choice() {
    # ask_choice "prompt" "opt1 opt2 opt3" "default" → prints chosen option.
    local prompt="$1" opts="$2" default="${3:-}" reply
    if $NON_INTERACTIVE; then
        echo "$default"
        return
    fi
    echo "$prompt" >&2
    local i=1
    for opt in $opts; do
        echo "  [$i] $opt" >&2
        i=$((i+1))
    done
    if [ -n "$default" ]; then
        local default_idx
        default_idx=$(echo "$opts" | tr ' ' '\n' | grep -n "^$default\$" | cut -d: -f1)
        read -rp "choose [1-$(echo "$opts" | wc -w)] (default $default_idx): " reply >&2
    else
        read -rp "choose [1-$(echo "$opts" | wc -w)]: " reply >&2
    fi
    [ -z "$reply" ] && reply=$(echo "$opts" | tr ' ' '\n' | grep -n "^$default\$" | cut -d: -f1)
    echo "$opts" | tr ' ' '\n' | sed -n "${reply}p"
}

# --- platform detection -----------------------------------------------------
detect_platform() {
    case "$(uname -s)" in
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        Darwin) echo "macos" ;;
        *) echo "unknown" ;;
    esac
}

PLATFORM="$(detect_platform)"
log "platform: $PLATFORM"

if [ "$PLATFORM" = "windows" ] && ! $NATIVE_WINDOWS; then
    cat >&2 <<EOF
[deploy] Native Windows detected. Bishon V2 targets Linux/WSL2 — native
         Windows is unsupported (paddlepaddle-gpu wheels incomplete, 9p
         SQLite WAL issues via Docker Desktop bind mounts).

         Open a WSL2 Ubuntu 22.04 terminal and run this script there:
           wsl -d Ubuntu-22.04
           cd /mnt/i/Bishon/V2/dev
           bash scripts/docker/bishon-deploy.sh

         To force native-Windows continuation anyway: --native-windows
EOF
    exit 1
fi

# --- load saved config ------------------------------------------------------
if [ -z "$LOAD_CONFIG" ] && [ -n "$HOST_DIR" ] && [ -f "$HOST_DIR/deploy.conf" ]; then
    LOAD_CONFIG="$HOST_DIR/deploy.conf"
fi
if [ -n "$LOAD_CONFIG" ] && [ -f "$LOAD_CONFIG" ]; then
    log "loading saved config from $LOAD_CONFIG"
    # shellcheck disable=SC1090
    source "$LOAD_CONFIG"
fi

# --- preflight (informational; shows what's ready) --------------------------
VERSION_FOR_PREFLIGHT="${TAG:-}"
if [ -z "$VERSION_FOR_PREFLIGHT" ] && [ -f "$REPO_ROOT/VERSION" ]; then
    VERSION_FOR_PREFLIGHT="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
fi
MODE_FOR_PREFLIGHT="${MODE:-release}"
log "=== preflight (informational; failures don't block) ==="
bash "$SCRIPT_DIR/preflight.sh" --mode "$MODE_FOR_PREFLIGHT" \
    ${VERSION_FOR_PREFLIGHT:+--version "$VERSION_FOR_PREFLIGHT"} \
    2>&1 | sed 's/^/  /' || true

# --- gather missing inputs --------------------------------------------------
if [ -z "$MODE" ]; then
    log ""
    MODE=$(ask_choice "Select deployment mode:" \
        "docker-online docker-offline bare-metal" "docker-online")
fi
log "mode: $MODE"

case "$MODE" in
    docker-online|docker-offline)
        [ -n "$HOST_DIR" ] && HOST_DIR=$(ask "host-dir path?" "$HOST_DIR")
        [ -z "$HOST_DIR" ] && die "--host-dir required for $MODE"
        mkdir -p "$HOST_DIR"

        [ -n "$RELEASE_TAR" ] || RELEASE_TAR=$(ask "release tarball path?" "")
        [ -z "$RELEASE_TAR" ] && die "--release required (run make-release.sh first)"

        if [ "$MODE" = "docker-online" ]; then
            IMAGE_SOURCE="${IMAGE_SOURCE:-pull}"
            if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "ghcr" ]; then
                REGISTRY=$(ask_choice "Registry?" "ghcr aliyun aliyun-vpc" "ghcr")
            fi
        else
            IMAGE_SOURCE="${IMAGE_SOURCE:-load}"
            [ -n "$IMAGE_TAR" ] || IMAGE_TAR=$(ask "image tarball path?" "")
            [ -z "$IMAGE_TAR" ] && die "--image <tar> required for docker-offline"
        fi

        if [ -z "$MODELS_SOURCE" ]; then
            MODELS_SOURCE=$(ask_choice "Models source?" "online tarball skip" "skip")
        fi
        if [ "$MODELS_SOURCE" = "tarball" ]; then
            [ -n "$MODELS_TAR" ] || MODELS_TAR=$(ask "models tarball path?" "")
            [ -z "$MODELS_TAR" ] && die "--models <tar> required with --models-source tarball"
        fi
        ;;

    bare-metal)
        [ -n "$SOURCE_DIR" ] || SOURCE_DIR=$(ask "source repo path?" "$REPO_ROOT")
        [ -z "$SOURCE_DIR" ] && die "--source-dir required for bare-metal"
        [ -d "$SOURCE_DIR/bishon_kernel" ] || die "$SOURCE_DIR is not a Bishon V2 repo"

        # Auto-detect conda env
        if [ -z "$CONDA_ENV" ]; then
            for cand in "/opt/miniconda3/envs/bishon" "$HOME/miniconda3/envs/bishon"; do
                [ -x "$cand/bin/python" ] && CONDA_ENV="$cand" && break
            done
        fi
        [ -n "$CONDA_ENV" ] || CONDA_ENV=$(ask "conda env path?" "")
        [ -n "$CONDA_ENV" ] || die "could not locate bishon conda env; pass --conda-env"

        if [ -z "$MODELS_SOURCE" ]; then
            MODELS_SOURCE=$(ask_choice "Models source?" "online tarball skip" "skip")
        fi
        if [ "$MODELS_SOURCE" = "tarball" ]; then
            [ -n "$MODELS_TAR" ] || MODELS_TAR=$(ask "models tarball path?" "")
        fi
        ;;

    *) die "unknown mode: $MODE (use docker-online|docker-offline|bare-metal)" ;;
esac

# --- summary ----------------------------------------------------------------
log ""
log "=== deployment summary ==="
log "  mode:          $MODE"
case "$MODE" in
    docker-*) log "  host-dir:      $HOST_DIR"
              log "  release:       $RELEASE_TAR"
              log "  image source:  $IMAGE_SOURCE"
              [ "$IMAGE_SOURCE" = "pull" ] && log "  registry:      $REGISTRY"
              [ -n "$IMAGE_TAR" ] && log "  image tar:     $IMAGE_TAR"
              ;;
    bare-metal) log "  source-dir:    $SOURCE_DIR"
                log "  conda env:     $CONDA_ENV"
                ;;
esac
log "  models source: $MODELS_SOURCE${MODELS_TAR:+ ($MODELS_TAR)}"

if ! $NON_INTERACTIVE; then
    confirm=$(ask "proceed?" "y")
    [ "$confirm" = "y" ] || { log "aborted"; exit 1; }
fi

# --- save config (skipped in dry-run mode; I1 fix) -------------------------
# NOTE: write must happen AFTER the dry-run check, otherwise --dry-run leaves
# a deploy.conf on disk — violating the dry-run contract that operators rely
# on for safe rehearsal deploys.
if ! $DRY_RUN && $SAVE_CONFIG && [ -n "$HOST_DIR" ]; then
    CONF="$HOST_DIR/deploy.conf"
    cat > "$CONF" <<EOF
# Auto-saved by bishon-deploy.sh $(date -Iseconds 2>/dev/null || echo "")
MODE="$MODE"
HOST_DIR="$HOST_DIR"
RELEASE_TAR="$RELEASE_TAR"
IMAGE_TAR="$IMAGE_TAR"
IMAGE_SOURCE="$IMAGE_SOURCE"
REGISTRY="$REGISTRY"
TAG="$TAG"
MODELS_SOURCE="$MODELS_SOURCE"
MODELS_TAR="$MODELS_TAR"
SOURCE_DIR="$SOURCE_DIR"
CONDA_ENV="$CONDA_ENV"
INSTALL_DEPS="$INSTALL_DEPS"
EOF
    log "config saved to $CONF"
fi

# --- dispatch ---------------------------------------------------------------
if $DRY_RUN; then
    log "(dry-run: not executing)"
    exit 0
fi

case "$MODE" in
    docker-online|docker-offline)
        DEPLOY_ARGS=(--host-dir "$HOST_DIR" --release "$RELEASE_TAR")
        case "$IMAGE_SOURCE" in
            pull)    DEPLOY_ARGS+=(--pull --registry "$REGISTRY") ;;
            load)    DEPLOY_ARGS+=(--image "$IMAGE_TAR") ;;
            existing) DEPLOY_ARGS+=(--image-source existing) ;;
        esac
        [ -n "$TAG" ] && DEPLOY_ARGS+=(--tag "$TAG")
        [ "$MODELS_SOURCE" = "tarball" ] && DEPLOY_ARGS+=(--models "$MODELS_TAR")
        bash "$SCRIPT_DIR/bishon-deploy-docker.sh" "${DEPLOY_ARGS[@]}"
        ;;
    bare-metal)
        BM_ARGS=(--source-dir "$SOURCE_DIR" --conda-env "$CONDA_ENV"
                 --models-source "$MODELS_SOURCE")
        $INSTALL_DEPS && BM_ARGS+=(--install-deps)
        [ "$MODELS_SOURCE" = "tarball" ] && BM_ARGS+=(--models "$MODELS_TAR")
        bash "$SCRIPT_DIR/bishon-deploy-bare-metal.sh" "${BM_ARGS[@]}"
        ;;
esac
