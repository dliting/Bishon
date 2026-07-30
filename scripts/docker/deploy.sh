#!/usr/bin/env bash
# scripts/docker/deploy.sh
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
#   bash deploy.sh
#
# Usage (non-interactive):
#   bash deploy.sh --non-interactive \
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
MODELS_DIR=""
SOURCE_DIR=""
CONDA_ENV=""
INSTALL_DEPS=false
NATIVE_WINDOWS=false
LOAD_CONFIG=""
SAVE_CONFIG=true
BUNDLE_DIR=""           # auto-detected: dir containing release/image/models tarballs

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
        --models-dir)      MODELS_DIR="$2"; MODELS_SOURCE="directory"; shift 2 ;;
        --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
        --conda-env)       CONDA_ENV="$2"; shift 2 ;;
        --install-deps)    INSTALL_DEPS=true; shift ;;
        --native-windows)  NATIVE_WINDOWS=true; shift ;;
        --load-config)     LOAD_CONFIG="$2"; shift 2 ;;
        --no-save-config)  SAVE_CONFIG=false; shift ;;
        --bundle-dir)      BUNDLE_DIR="$2"; shift 2 ;;
        --help|-h)
            cat <<'EOF'
deploy.sh — Interactive deployment wizard for Bishon V2.

Three modes:
  docker-online   Pull image from ghcr.io / Aliyun, run in Docker. (Recommended.)
  docker-offline  Load image from local docker save tar, run in Docker.
  bare-metal      Run uvicorn directly with the bishon conda env. (No Docker.)

USAGE
  bash deploy.sh                              # interactive
  bash deploy.sh --non-interactive [flags...] # CI / batch deploy

FLAGS (every interactive question has a corresponding flag)
  --mode <m>             Deployment mode (docker-online|docker-offline|bare-metal).
  --host-dir <dir>       Where state lives (Docker modes only).
                         MUST be ext4 (SQLite WAL fails on 9p/drvfs).
  --release <tar.gz>     Main release tarball from make-release.sh.
                         Always required for Docker modes (carries env + source).
  --image <tar>          Local image tarball (docker-offline mode).
  --pull                 Pull image from registry at install time (docker-online).
  --image-source <src>   load | pull | existing (advanced; usually use --image/--pull).
  --registry <r>         ghcr (default) | aliyun | aliyun-vpc | <full-url>.
                         Used with --pull.
  --tag <ver>            Image tag. Default: read from VERSION file.
  --models-source <s>    online (hf-mirror.com + paddleocr auto) | tarball | skip.
  --models <tar.gz>      Local models tarball (when --models-source tarball).
  --models-dir <dir>     Path to existing models/ dir (when --models-source directory).
  --source-dir <path>    Bishon V2 repo root (bare-metal mode).
  --conda-env <path>     Path to bishon conda env (bare-metal; auto-detected if omitted).
  --install-deps         Re-run pip install -r requirements.txt (bare-metal).
  --bundle-dir <dir>     Dir containing release/image/models tarballs. Auto-detected
                         in $PWD or script dir for offline mode; saves typing paths.
  --load-config <path>   Read defaults from a saved config file.
  --no-save-config       Skip writing <host-dir>/deploy.conf.
  --native-windows       Bypass native-Windows warning (unsupported, use WSL2).
  --non-interactive      Disable prompts; every question becomes a flag.
  --dry-run              Walk through everything, print plan, no side effects.

CONFIG PERSISTENCE
  After a successful (non-dry-run) run, choices are saved to
  <host-dir>/deploy.conf. Next run reads it as defaults. Override with flags
  or --load-config.

PLATFORM DETECTION
  Native Windows (MSYS/Cygwin/cmd) is refused unless --native-windows.
  WSL/Linux proceed normally. Run inside `wsl -d Ubuntu-22.04` for Windows.

EXAMPLES
  Interactive wizard:
    bash deploy.sh

  Non-interactive Docker pull from Aliyun, models online:
    bash deploy.sh --non-interactive \
        --mode docker-online --host-dir /var/lib/bishon \
        --release bishon-release-2.2.0.tar.gz \
        --registry aliyun --models-source online

  Non-interactive bare-metal, no models, no pip reinstall:
    bash deploy.sh --non-interactive \
        --mode bare-metal --source-dir /opt/Bishon/V2/dev \
        --models-source skip

  Dry-run (no side effects, prints plan):
    bash deploy.sh --non-interactive --dry-run \
        --mode docker-offline --host-dir /var/lib/bishon \
        --release r.tar.gz --image i.tar
EOF
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

ask_required() {
    # ask_required "prompt" "default" → prints non-empty user input. If user
    # presses Enter with no input AND no default is given, prompts again
    # (interactive mode only). Non-interactive with empty default → die.
    local prompt="$1" default="${2:-}" reply
    if $NON_INTERACTIVE; then
        if [ -z "$default" ]; then
            die "ask_required: $prompt (no default and --non-interactive)"
        fi
        echo "$default"
        return
    fi
    while true; do
        if [ -n "$default" ]; then
            read -rp "$prompt [$default] " reply
            reply="${reply:-$default}"
        else
            read -rp "$prompt " reply
        fi
        [ -n "$reply" ] && { echo "$reply"; return; }
        echo "  (required, please enter a value)" >&2
    done
}

ask_path() {
    # ask_path "prompt" "default" → like ask_required, but also verifies the
    # path exists on disk. Loops on missing paths in interactive mode.
    local prompt="$1" default="${2:-}" reply
    if $NON_INTERACTIVE; then
        if [ -z "$default" ]; then
            if $DRY_RUN; then
                echo "[deploy]   (not specified: $prompt)" >&2
                return
            fi
            die "ask_path: $prompt (no default and --non-interactive)"
        fi
        if [ ! -e "$default" ]; then
            if $DRY_RUN; then
                echo "[deploy]   (not found: $prompt — $default)" >&2
                return
            fi
            die "ask_path: $default does not exist"
        fi
        echo "$default"
        return
    fi
    while true; do
        if [ -n "$default" ]; then
            read -rp "$prompt [$default] " reply
            reply="${reply:-$default}"
        else
            read -rp "$prompt " reply
        fi
        if [ -z "$reply" ]; then
            echo "  (required)" >&2
            continue
        fi
        if [ -e "$reply" ]; then
            echo "$reply"
            return
        fi
        echo "  path not found: $reply — try again" >&2
    done
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
           bash scripts/docker/deploy.sh

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

# --- environment detection (informs mode defaults) -------------------------
# --- bundle detection -----------------------------------------------------
# Look for a deploy bundle dir: check $PWD (operator cd'd into it), then the
# parent of the script's own directory (when running from inside the bundle's
# scripts/ subdirectory via deploy.sh wrapper).
# Sets BUNDLE_DIR, BUNDLE_SOURCE_DIR, and auto-globs release/image/models tarballs.
if [ -z "$BUNDLE_DIR" ]; then
    for cand in "$PWD" "$(dirname "$SCRIPT_DIR")"; do
        if ls "$cand"/bishon-release-*.tar.gz >/dev/null 2>&1; then
            BUNDLE_DIR="$cand"
            log "auto-detected bundle dir: $BUNDLE_DIR"
            break
        fi
    done
fi
if [ -n "$BUNDLE_DIR" ]; then
    # Use the bundle's bishon/ subdir (extracted source) for preflight checks.
    if [ -d "$BUNDLE_DIR/bishon/bishon_kernel" ]; then
        BUNDLE_SOURCE_DIR="$BUNDLE_DIR/bishon"
    else
        BUNDLE_SOURCE_DIR="$BUNDLE_DIR"
    fi

    # Re-define glob_bundle for the closed-over $BUNDLE_DIR context.
    glob_bundle() {
        local var="$1" pattern="$2" descr="$3"
        [ -n "${!var:-}" ] && return 0
        local matches
        matches=$(ls "$BUNDLE_DIR"/$pattern 2>/dev/null | sort) || true  # ls exits 2 on no match → pipefail → set -e; || true guards it
        if [ -z "$matches" ]; then
            return 0   # no match; nothing to auto-detect
        fi
        line_count=$(echo "$matches" | wc -l)
        if [ "$line_count" -eq 1 ]; then
            printf -v "$var" "%s" "$matches"
            log "auto-detected $descr: ${!var}"
        fi
    }
    glob_bundle RELEASE_TAR 'bishon-release-*.tar.gz' 'release tarball'
    glob_bundle IMAGE_TAR   'bishon-cuda-image-*.tar' 'image tarball'
    glob_bundle MODELS_TAR  'bishon-models-*.tar.gz'  'models tarball'
    # If models tarball detected, switch default models-source to tarball.
    if [ -n "$MODELS_TAR" ] && [ -z "$MODELS_SOURCE" ]; then
        MODELS_SOURCE="tarball"
    fi
else
    glob_bundle() { : ; }  # no-op when no bundle dir
fi

# Suggest default mode based on what's available:
#   bundle in PWD + docker available → docker-offline
#   no bundle + docker available      → docker-online
#   no docker                          → bare-metal
if [ -z "$MODE" ]; then
    if [ -n "$BUNDLE_DIR" ]; then
        DEFAULT_MODE="docker-offline"
    elif command -v docker >/dev/null 2>&1; then
        DEFAULT_MODE="docker-online"
    else
        DEFAULT_MODE="bare-metal"
    fi
else
    DEFAULT_MODE="$MODE"
fi

# Default host-dir: ./bishon-data (next to wherever the operator is running).
[ -z "$HOST_DIR" ] && HOST_DIR="./bishon-data"

# --- preflight (informational; shows what's ready) --------------------------
VERSION_FOR_PREFLIGHT="${TAG:-}"
if [ -z "$VERSION_FOR_PREFLIGHT" ]; then
    # In bundle context, VERSION lives at bundle root (copied by make-release.sh).
    # In repo context, REPO_ROOT/VERSION is the source of truth.
    if [ -n "$BUNDLE_DIR" ] && [ -f "$BUNDLE_DIR/VERSION" ]; then
        VERSION_FOR_PREFLIGHT="$(tr -d '[:space:]' < "$BUNDLE_DIR/VERSION")"
    elif [ -f "$REPO_ROOT/VERSION" ]; then
        VERSION_FOR_PREFLIGHT="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
    fi
fi
MODE_FOR_PREFLIGHT="${DEFAULT_MODE}"
log "=== preflight (informational; failures don't block) ==="
PREFLIGHT_ARGS=(--mode "$MODE_FOR_PREFLIGHT")
[ -n "$VERSION_FOR_PREFLIGHT" ] && PREFLIGHT_ARGS+=(--version "$VERSION_FOR_PREFLIGHT")
# When running from a bundle, pass the source dir so preflight can find
# bishon_kernel/bishon_server/dist/. Models are at the bundle root level
# (not inside bishon/), so pass a separate --models-dir.
if [ -n "${BUNDLE_SOURCE_DIR:-}" ]; then
    export CONDA_ROOT="${CONDA_ROOT:-/opt/miniconda3}"
    export ENV_SRC="${CONDA_ROOT}/envs/bishon"
    PREFLIGHT_ARGS+=(--source-dir "$BUNDLE_SOURCE_DIR")
    PREFLIGHT_ARGS+=(--models-dir "$BUNDLE_DIR/models")
fi
bash "$SCRIPT_DIR/preflight.sh" "${PREFLIGHT_ARGS[@]}" 2>&1 | sed 's/^/  /' || true

# --- gather missing inputs --------------------------------------------------
if [ -z "$MODE" ]; then
    log ""
    MODE=$(ask_choice \
        "Select deployment mode:
  docker-online   = pull image from ghcr.io / Aliyun, run in Docker (recommended)
  docker-offline  = load image from local tar, run in Docker (internal/air-gap)
  bare-metal      = run uvicorn directly, no Docker" \
        "docker-online docker-offline bare-metal" "$DEFAULT_MODE")
fi
log "mode: $MODE"

case "$MODE" in
    docker-online|docker-offline)
        [ -n "$HOST_DIR" ] || HOST_DIR=$(ask_required \
            "host-dir path? (where state lives; MUST be ext4 — SQLite WAL fails on 9p/drvfs)" \
            "$HOST_DIR")
        mkdir -p "$HOST_DIR"

        # For offline mode: try to auto-detect a "bundle dir" containing
        # release/image/models tarballs. Look in $PWD, $HOST_DIR's parent,
        # and the script's own directory. (Bundle detection already ran in the
        # environment-detection section above; this block only supplements if
        # BUNDLE_DIR somehow wasn't found then but is discoverable now.)
        if [ "$MODE" = "docker-offline" ] && [ -z "$BUNDLE_DIR" ]; then
            for cand in "$PWD" "$(dirname "$HOST_DIR")" "$(dirname "$0")"; do
                if ls "$cand"/bishon-release-*.tar.gz >/dev/null 2>&1; then
                    BUNDLE_DIR="$cand"
                    log "auto-detected bundle dir: $BUNDLE_DIR"
                    break
                fi
            done
        fi

        [ -n "$RELEASE_TAR" ] || RELEASE_TAR=$(ask_path \
            "release tarball path? (from make-release.sh; carries env + source)" \
            "$RELEASE_TAR")

        if [ "$MODE" = "docker-online" ]; then
            IMAGE_SOURCE="${IMAGE_SOURCE:-pull}"
            if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "ghcr" ]; then
                REGISTRY=$(ask_choice \
                    "Registry?
  ghcr       = ghcr.io (海外)
  aliyun     = crpi-...cn-beijing.personal.cr.aliyuncs.com (国内推荐)
  aliyun-vpc = 同上但走阿里云 VPC 内网（ECS 部署更快）" \
                    "ghcr aliyun aliyun-vpc" "ghcr")
            fi
        else
            IMAGE_SOURCE="${IMAGE_SOURCE:-load}"
            if [ -z "$IMAGE_TAR" ]; then
                # If docker image exists locally but the tar wasn't shipped in the
                # bundle, auto-save it now so the user doesn't have to type a path.
                LOCAL_IMAGE="bishon-cuda:${TAG:-$(head -1 "$BUNDLE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo unknown)}"
                if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
                    log "docker image $LOCAL_IMAGE exists locally — saving as tarball"
                    IMAGE_TAR="$BUNDLE_DIR/$LOCAL_IMAGE.tar"   # bishon-cuda:2.1.0.tar
                    docker save "$LOCAL_IMAGE" -o "$IMAGE_TAR"
                    log "saved $IMAGE_TAR (use --skip-image in make-release.sh to avoid this step)"
                fi
            fi
            [ -n "$IMAGE_TAR" ] || IMAGE_TAR=$(ask_path \
                "image tarball path? (from build.sh + docker save)" \
                "$IMAGE_TAR")
        fi

        if [ -z "$MODELS_SOURCE" ]; then
            MODELS_SOURCE=$(ask_choice \
                "Models source?
  online    = download Qwen3-Reranker (hf-mirror.com) + PaddleOCR auto
  tarball   = extract from local bishon-models-*.tar.gz
  directory = use an existing models/ dir (symlink) [default: /opt/models]
  skip      = install without models (Rerank off, OCR warns at startup)" \
                "online tarball directory skip" "skip")
        fi
        if [ "$MODELS_SOURCE" = "tarball" ]; then
            [ -n "$MODELS_TAR" ] || MODELS_TAR=$(ask_path \
                "models tarball path? (from make-release.sh)" "$MODELS_TAR")
        fi
        if [ "$MODELS_SOURCE" = "directory" ]; then
            [ -n "$MODELS_DIR" ] || MODELS_DIR=$(ask_path \
                "models directory path? (existing dir with Qwen3-Reranker-0.6B/ and paddleocr_models/)" \
                "${MODELS_DIR:-/opt/models}")
        fi
        ;;

    bare-metal)
        [ -n "$SOURCE_DIR" ] || SOURCE_DIR=$(ask_path \
            "source repo path? (Bishon V2 repo root, containing bishon_kernel/)" \
            "${SOURCE_DIR:-$REPO_ROOT}")
        [ -d "$SOURCE_DIR/bishon_kernel" ] || die "$SOURCE_DIR is not a Bishon V2 repo (no bishon_kernel/)"

        # Auto-detect conda env
        if [ -z "$CONDA_ENV" ]; then
            for cand in "/opt/miniconda3/envs/bishon" "$HOME/miniconda3/envs/bishon"; do
                [ -x "$cand/bin/python" ] && CONDA_ENV="$cand" && break
            done
        fi
        [ -n "$CONDA_ENV" ] || CONDA_ENV=$(ask_path \
            "conda env path? (containing bin/python with all deps)" \
            "$CONDA_ENV")

        if [ -z "$MODELS_SOURCE" ]; then
            MODELS_SOURCE=$(ask_choice \
                "Models source?
  online    = download Qwen3-Reranker (hf-mirror.com) + PaddleOCR auto
  tarball   = extract from local bishon-models-*.tar.gz
  directory = symlink an existing models/ dir [default: /opt/models]
  skip      = no models (Rerank off, OCR warns at startup)" \
                "online tarball directory skip" "skip")
        fi
        if [ "$MODELS_SOURCE" = "tarball" ]; then
            [ -n "$MODELS_TAR" ] || MODELS_TAR=$(ask_path \
                "models tarball path? (from make-release.sh)" "$MODELS_TAR")
        fi
        if [ "$MODELS_SOURCE" = "directory" ]; then
            [ -n "$MODELS_DIR" ] || MODELS_DIR=$(ask_path \
                "models directory path? (existing dir with models/ subdirs)" \
                "${MODELS_DIR:-/opt/models}")
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
              if [ "$IMAGE_SOURCE" = "pull" ]; then log "  registry:      $REGISTRY"; fi
              if [ "$IMAGE_SOURCE" = "load" ] && [ -n "$IMAGE_TAR" ]; then
                  log "  image tar:     $IMAGE_TAR"
              fi
              ;;
    bare-metal) log "  source-dir:    $SOURCE_DIR"
                log "  conda env:     $CONDA_ENV"
                ;;
esac
log "  models source: $MODELS_SOURCE${MODELS_TAR:+ ($MODELS_TAR)}${MODELS_DIR:+ ($MODELS_DIR)}"

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
# Auto-saved by deploy.sh $(date -Iseconds 2>/dev/null || echo "")
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
EOF
    log "config saved to $CONF"
fi

# --- dispatch ---------------------------------------------------------------
if $DRY_RUN; then
    log "(dry-run: not executing)"
    exit 0
fi

# Handle models directory: symlink it in before starting deployment.
if [ "$MODELS_SOURCE" = "directory" ] && [ -d "$MODELS_DIR" ]; then
    case "$MODE" in
        docker-online|docker-offline)
            rm -f "$HOST_DIR/models" 2>/dev/null || true
            ln -sfn "$MODELS_DIR" "$HOST_DIR/models"
            log "linked $HOST_DIR/models → $MODELS_DIR"
            ;;
        bare-metal)
            rm -f "$SOURCE_DIR/models" 2>/dev/null || true
            ln -sfn "$MODELS_DIR" "$SOURCE_DIR/models"
            log "linked $SOURCE_DIR/models → $MODELS_DIR"
            ;;
    esac
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
        if [ "$MODELS_SOURCE" = "tarball" ]; then DEPLOY_ARGS+=(--models "$MODELS_TAR"); fi
        if [ "$MODELS_SOURCE" = "directory" ]; then DEPLOY_ARGS+=(--models-dir "$MODELS_DIR"); fi
        bash "$SCRIPT_DIR/deploy-docker.sh" "${DEPLOY_ARGS[@]}"
        ;;
    bare-metal)
        BM_ARGS=(--source-dir "$SOURCE_DIR" --conda-env "$CONDA_ENV"
                 --models-source "$MODELS_SOURCE")
        if $INSTALL_DEPS; then BM_ARGS+=(--install-deps); fi
        if [ "$MODELS_SOURCE" = "tarball" ]; then BM_ARGS+=(--models "$MODELS_TAR"); fi
        if [ "$MODELS_SOURCE" = "directory" ]; then BM_ARGS+=(--models-dir "$MODELS_DIR"); fi
        bash "$SCRIPT_DIR/deploy-bare-metal.sh" "${BM_ARGS[@]}"
        ;;
esac
