#!/usr/bin/env bash
# wizard.sh — 4 步交互向导。被 deploy.sh source 执行。
# 不直接执行——继承 deploy.sh 的 set -euo pipefail 和变量。
# 
# 设置以下变量后返回到 deploy.sh：
#   MODE, HOST_DIR, RELEASE_TAR, IMAGE_TAR, IMAGE_SOURCE,
#   REGISTRY, TAG, MODELS_SOURCE, MODELS_TAR, MODELS_DIR,
#   SOURCE_DIR, CONDA_ENV, INSTALL_DEPS, BUNDLE_DIR

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


# ===== Step 1-4: Gather inputs =====
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
                "image tarball path? (from build-image.sh + docker save)" \
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
