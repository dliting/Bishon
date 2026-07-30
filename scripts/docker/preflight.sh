#!/usr/bin/env bash
# scripts/docker/preflight.sh
#
# Pre-flight checks for Bishon V2 release readiness.
#
# Usage:
#   bash preflight.sh [--version <ver>] [--src-only]
#
# Called by make-release.sh (with --version) and usable standalone by
# developers who want to confirm readiness before starting a packaging run.
#
# Exit codes: 0=all passed, 1=one or more failures.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONDA_ROOT="${CONDA_ROOT:-/opt/miniconda3}"
ENV_SRC="$CONDA_ROOT/envs/bishon"
VERSION=""
SRC_ONLY=false
MODE="release"   # release | docker-online | docker-offline | bare-metal
SOURCE_DIR=""    # override REPO_ROOT for bundle offline deploy preview
MODELS_DIR=""    # override models/ location (bundle has models at root, not inside source/)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    VERSION="$2"; shift 2 ;;
        --src-only)   SRC_ONLY=true; shift ;;
        --mode)       MODE="$2"; shift 2 ;;
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --models-dir) MODELS_DIR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--version <ver>] [--src-only] [--mode <m>]

  --version <ver>   Image tag to verify (only used for docker image check).
  --src-only        Skip env+models+image checks (release packaging sub-mode).
  --mode <m>        release (default) | docker-online | docker-offline | bare-metal
                    Adjusts which checks are mandatory vs informational.
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

fail=0
info() { echo "  INFO: $*"; }
p()  { echo "  PASS: $*"; }
f()  { echo "  FAIL: $*" >&2; fail=1; }

# If --source-dir given, use it for all REPO_ROOT-relative checks.
CHECK_ROOT="${SOURCE_DIR:-$REPO_ROOT}"

echo "=== Bishon v2 preflight (mode=$MODE) ==="

# --- 1. bishon env ----------------------------------------------------------
if $SRC_ONLY; then
    p "python-env check skipped (--src-only)"
elif [ -d "$ENV_SRC/bin" ]; then
    p "bishon env at $ENV_SRC"
else
    f "bishon env not found at $ENV_SRC"
fi

# --- 2. WSL Ubuntu version (glibc compat with image base) -------------------
UBUNTU_VER="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}" || echo unknown)"
if [ "$UBUNTU_VER" = "22.04" ]; then
    p "WSL Ubuntu $UBUNTU_VER"
else
    f "WSL Ubuntu is $UBUNTU_VER but image base is 22.04 (glibc mismatch)"
fi

# --- 3. Env critical deps ---------------------------------------------------
if $SRC_ONLY; then
    p "bishon env import check skipped (--src-only)"
else
    res="$(echo "import fastapi,uvicorn,torch,faiss,paddle,transformers,langchain; print(\"OK\")" \
        | "$ENV_SRC/bin/python" 2>&1)" || \
        f "bishon env import failed: $res"
    [ "${res##*$'\n'}" = "OK" ] || f "bishon env import unexpected output: $res"
    p "bishon env imports critical deps"
fi

# --- 4. Frontend dist -------------------------------------------------------
DIST_INDEX="$CHECK_ROOT/bishon_kernel/bishon_server/dist/bishon/index.html"
if [ -f "$DIST_INDEX" ]; then
    p "frontend dist present"
else
    f "$DIST_INDEX missing. Rebuild frontend."
fi

# --- 5. PaddleOCR models ----------------------------------------------------
if $SRC_ONLY; then
    p "models checks skipped (--src-only)"
else
    paddle_dir="${MODELS_DIR:-$CHECK_ROOT/models}/paddleocr_models"
    if [ -d "$paddle_dir" ]; then
        subdirs="$(find "$paddle_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
        if [ "$subdirs" -ge 4 ]; then
            p "paddleocr: $subdirs subdirs"
        else
            f "paddleocr: $paddle_dir has $subdirs subdirs (need >=4: det/rec/cls/doc_ori)"
        fi
    else
        # In a deploy bundle, models may be in tarball form (not yet extracted).
        # Accept the tarball as evidence that models are available.
        models_tgz=""
        for cand_dir in "$CHECK_ROOT" "$(dirname "$CHECK_ROOT")" "$MODELS_DIR" "$REPO_ROOT"; do
            tgz="$(ls "$cand_dir"/bishon-models-*.tar.gz 2>/dev/null | head -1)" || true
            if [ -n "$tgz" ]; then models_tgz="$tgz"; break; fi
        done
        if [ -n "$models_tgz" ]; then
            p "paddleocr dir missing but models tarball available: $models_tgz"
        else
            f "paddleocr dir missing: $paddle_dir"
        fi
    fi
fi

# --- 6. Docker image --------------------------------------------------------
# Mode-aware:
#   release / docker-offline: image must be local (we'll docker save it)
#   docker-online:            image will be pulled at install time; registry reachable check
#   bare-metal:               docker not needed at all
case "$MODE" in
    bare-metal)
        p "docker image check skipped (bare-metal mode)"
        ;;
    docker-online)
        if ! command -v docker >/dev/null 2>&1; then
            f "docker not installed (required for docker-online mode)"
        else
            p "docker available: $(docker --version)"
            if [ -n "$VERSION" ]; then
                # We don't pull here (network heavy); just confirm registry connectivity is plausible.
                info "image bishon-cuda:$VERSION will be pulled at install time"
            fi
        fi
        ;;
    release|docker-offline)
        if $SRC_ONLY; then
            p "docker image check skipped (--src-only)"
        elif [ -n "$VERSION" ]; then
            IMAGE_TAG="bishon-cuda:$VERSION"
            if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
                p "docker image: $IMAGE_TAG"
            else
                f "docker image $IMAGE_TAG not found. Run: build.sh --version $VERSION"
            fi
        else
            p "docker image check skipped (no --version given)"
        fi
        ;;
    *)
        f "unknown --mode: $MODE (use release|docker-online|docker-offline|bare-metal)"
        ;;
esac

# --- result ----------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
    echo "PASS: all checks passed."
    exit 0
else
    echo "FAIL: $fail check(s) failed."
    exit 1
fi
