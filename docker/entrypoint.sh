#!/usr/bin/env bash
# Bishon V2 container entrypoint (orchestrator).
#
# Logic lives in sibling entrypoint_lib/*.sh modules — source them and call
# the public function from each. Each module < 60 lines, single responsibility,
# independently testable (bats source + call).
#
# The container is started with:
#   -v <host-dir>:/opt/bishon-home
#   --env-file <host-dir>/.env
#
# Fail loudly (exit non-zero) on any precondition violation — better than
# a half-started service that silently misbehaves.

set -euo pipefail

DATA_ROOT=/opt/bishon-home
ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$ENTRYPOINT_DIR/entrypoint_lib"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# --- 1. Volume layout validation --------------------------------------------
[ -d "$DATA_ROOT/python-env/bin" ]        || die "$DATA_ROOT/python-env missing or incomplete. Run install.sh."
[ -f "$DATA_ROOT/.env" ]                  || die "$DATA_ROOT/.env missing. Run install.sh."
[ -d "$DATA_ROOT/bishon/bishon_kernel" ]  || die "$DATA_ROOT/bishon/bishon_kernel missing. Run upgrade.sh."
[ -d "$DATA_ROOT/models" ]                || die "$DATA_ROOT/models missing. Run install.sh."

# --- 2. Set environment for model paths and offline cache --------------------
# Set these before sourcing lib modules so any future code that references
# them sees the correct values. MODELS_DIR tells model_config.py where to
# find model files; TIKTOKEN_CACHE_DIR avoids network downloads at runtime.
export MODELS_DIR=$DATA_ROOT/models
export TIKTOKEN_CACHE_DIR=$DATA_ROOT/models/tiktoken_cache
mkdir -p "$TIKTOKEN_CACHE_DIR"

# --- 3. Source lib modules --------------------------------------------------
[ -d "$LIB_DIR" ] || die "$LIB_DIR missing — release tarball incomplete."
source "$LIB_DIR/bind_python_env.sh"
source "$LIB_DIR/redirect_runtime_dirs.sh"
source "$LIB_DIR/bind_node_env.sh"
source "$LIB_DIR/frontend_rebuild.sh"

# --- 4. Run setup steps in order --------------------------------------------
bind_python_env           # existing: symlink python-env into miniconda3 path
redirect_runtime_dirs     # redirect BISHON_DB + logs to host-dir top
bind_node_env             # no-op if $DATA_ROOT/node-env/ missing
maybe_rebuild_frontend    # no-op if Node not bound

# --- 5. Launch uvicorn ------------------------------------------------------
PY="/opt/miniconda3/envs/bishon/bin/python"
[ -x "$PY" ] || die "$PY not executable. python-env may be corrupted."
cd "$DATA_ROOT/bishon"

# Log resolved LLM/embedding endpoints (no keys) so ops can debug
# "container started but LLM unreachable" without docker exec.
log "OPENAI_API_BASE=${OPENAI_API_BASE:-(unset)}"
log "EMBEDDING_API_BASE=${EMBEDDING_API_BASE:-(unset)}"
log "OPENAI_API_MODEL_NAME=${OPENAI_API_MODEL_NAME:-(unset)}"
log "EMBEDDING_MODEL_NAME=${EMBEDDING_MODEL_NAME:-(unset)}"
log "RERANK_ENABLED=${RERANK_ENABLED:-false}  VECTOR_DB_USE_GPU=${VECTOR_DB_USE_GPU:-true}  OCR_USE_GPU=${OCR_USE_GPU:-true}"
log "starting uvicorn (cwd=$(pwd))"
exec "$PY" -m uvicorn bishon_kernel.bishon_server.app:app \
    --host 0.0.0.0 --port 8777 --log-level info
