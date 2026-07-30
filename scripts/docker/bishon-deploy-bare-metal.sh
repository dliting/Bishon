#!/usr/bin/env bash
# scripts/docker/bishon-deploy-bare-metal.sh
#
# L2 deployment module: Bare-metal mode. No Docker. Just:
#   1. preflight --mode bare-metal (env, WSL Ubuntu, deps)
#   2. pip install -r requirements.txt (if --install-deps)
#   3. bash scripts/download-models.sh (if --models-source online)
#   4. bash start.sh
#
# Usually invoked by bishon-deploy.sh (the wizard). Can also be called
# directly when the user knows they want bare-metal.
#
# Usage:
#   bash bishon-deploy-bare-metal.sh --source-dir <repo> [--conda-env <path>]
#       [--models-source online|tarball|skip] [--models <tar>]
#       [--install-deps] [--no-start] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SOURCE_DIR=""
CONDA_ENV=""
MODELS_SOURCE="skip"
MODELS_TAR=""
INSTALL_DEPS=false
START_AFTER=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)    SOURCE_DIR="$2"; shift 2 ;;
        --conda-env)     CONDA_ENV="$2"; shift 2 ;;
        --models-source) MODELS_SOURCE="$2"; shift 2 ;;
        --models)        MODELS_TAR="$2"; shift 2 ;;
        --install-deps)  INSTALL_DEPS=true; shift ;;
        --no-start)      START_AFTER=false; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=deploy-bare-metal
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

[ -n "$SOURCE_DIR" ] || die "--source-dir <repo> required"
[ -d "$SOURCE_DIR/bishon_kernel" ] || die "$SOURCE_DIR does not look like a Bishon V2 repo (no bishon_kernel/)"

# Default conda env: auto-detect or use well-known path.
if [ -z "$CONDA_ENV" ]; then
    for cand in "/opt/miniconda3/envs/bishon" "$HOME/miniconda3/envs/bishon"; do
        if [ -x "$cand/bin/python" ]; then
            CONDA_ENV="$cand"
            break
        fi
    done
fi
[ -n "$CONDA_ENV" ] || die "could not find bishon conda env. Pass --conda-env <path>."
[ -x "$CONDA_ENV/bin/python" ] || die "$CONDA_ENV/bin/python not executable"

PY="$CONDA_ENV/bin/python"

if $DRY_RUN; then
    log "=== DRY RUN: bare-metal deployment ==="
    log "source-dir: $SOURCE_DIR"
    log "conda env:  $CONDA_ENV"
    log "models:     $MODELS_SOURCE${MODELS_TAR:+ ($MODELS_TAR)}"
    log "install-deps: $INSTALL_DEPS"
    log "start:        $START_AFTER"
    exit 0
fi

# --- 1. preflight -----------------------------------------------------------
log "=== Step 1/4: preflight ==="
bash "$SCRIPT_DIR/preflight.sh" --mode bare-metal || \
    die "preflight failed (use --skip-preflight once you've addressed the issues)"

# --- 2. Optional pip install ------------------------------------------------
if $INSTALL_DEPS; then
    log "=== Step 2/4: pip install -r requirements.txt ==="
    "$PY" -m pip install -r "$SOURCE_DIR/requirements.txt"
else
    log "=== Step 2/4: skip pip install (--install-deps to enable) ==="
fi

# --- 3. Models --------------------------------------------------------------
log "=== Step 3/4: models ($MODELS_SOURCE) ==="
case "$MODELS_SOURCE" in
    skip)
        log "skipping models (operator's responsibility)"
        ;;
    online)
        bash "$SOURCE_DIR/scripts/download-models.sh" --target "$SOURCE_DIR/models" \
            || die "download-models.sh failed"
        ;;
    tarball)
        [ -n "$MODELS_TAR" ] || die "--models <tar> required with --models-source tarball"
        [ -f "$MODELS_TAR" ] || die "models tar not found: $MODELS_TAR"
        bash "$SOURCE_DIR/scripts/download-models.sh" --target "$SOURCE_DIR/models" --offline "$MODELS_TAR" \
            || die "models extraction failed"
        ;;
    *) die "unknown --models-source: $MODELS_SOURCE (use online|tarball|skip)" ;;
esac

# --- 4. start.sh ------------------------------------------------------------
if $START_AFTER; then
    log "=== Step 4/4: start.sh ==="
    cd "$SOURCE_DIR"
    # start.sh expects to be run from repo root and uses current Python.
    # Ensure the bishon env's bin is on PATH so `python` resolves correctly.
    export PATH="$CONDA_ENV/bin:$PATH"
    bash "$SOURCE_DIR/start.sh"
else
    log "=== Step 4/4: skip start (--no-start) ==="
fi

log "=== Bare-metal deployment complete ==="
log "Service: http://localhost:8777/bishon/"
log "Stop:    pkill -f 'uvicorn bishon_kernel'"
