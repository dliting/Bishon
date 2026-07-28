#!/usr/bin/env bash
# Bishon V2 container entrypoint.
#
# Responsibilities:
#   1. Validate that the bind-mounted /opt/bishon-data has the expected layout.
#   2. Symlink /opt/miniconda3/envs/bishon -> /opt/bishon-data/bishon-env so
#      baked-in absolute paths inside the env resolve correctly.
#   3. cd into the source dir and exec uvicorn.
#
# The container MUST be started with:
#   -v <host-dir>:/opt/bishon-data
#   --env-file <host-dir>/.env
#
# Fail loudly (exit non-zero) on any precondition violation — better than
# a half-started service that silently misbehaves.

set -euo pipefail

DATA_ROOT=/opt/bishon-data
ENV_LINK=/opt/miniconda3/envs/bishon
PY="$ENV_LINK/bin/python"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# --- 1. Volume layout validation --------------------------------------------
[ -d "$DATA_ROOT/bishon-env/bin" ] || \
    die "$DATA_ROOT/bishon-env missing or incomplete. Run bishon-install.sh."
[ -f "$DATA_ROOT/.env" ] || \
    die "$DATA_ROOT/.env missing. Run bishon-install.sh."
[ -d "$DATA_ROOT/bishon/bishon_kernel" ] || \
    die "$DATA_ROOT/bishon/bishon_kernel missing. Run bishon-publish.sh."
[ -d "$DATA_ROOT/models" ] || \
    die "$DATA_ROOT/models missing. Run bishon-install.sh."

# --- 2. Symlink the bind-mounted env into miniconda3 standard path -----------
# This makes baked-in shebangs and absolute paths inside the env (which were
# /opt/miniconda3/envs/bishon/... when the env was created in WSL) resolve
# correctly inside the container.
mkdir -p /opt/miniconda3/envs
if [ ! -e "$ENV_LINK" ]; then
    ln -s "$DATA_ROOT/bishon-env" "$ENV_LINK"
    log "linked $ENV_LINK -> $DATA_ROOT/bishon-env"
elif [ ! -L "$ENV_LINK" ]; then
    die "$ENV_LINK exists but is not a symlink. Container state corrupted."
fi

# --- 2b. Redirect source-relative BISHON_DB and logs to the host-dir top ------
# Why: model_config.py / faiss_client.py / custom_log.py compute paths as
# root_path/BISHON_DB/{metadata.db,faiss,content} and root_path/logs/{debug,qa}.
# root_path is the source dir (/opt/bishon-data/bishon), so without redirection
# those writes would land INSIDE the source dir — getting wiped on publish and
# (in WSL tests) hitting NTFS via 9p, which breaks SQLite WAL.
# We want them at /opt/bishon-data/{BISHON_DB,logs} (sibling of source),
# preserved across publishes. Symlinks do this transparently to the app code.
redirect_dir() {
    local name="$1"      # e.g. BISHON_DB
    local target="$DATA_ROOT/$name"
    local link="$DATA_ROOT/bishon/$name"
    mkdir -p "$target"
    if [ -L "$link" ]; then
        return 0
    fi
    if [ ! -e "$link" ]; then
        ln -s "$target" "$link"
        log "linked $link -> $target"
        return 0
    fi
    # Exists as a real dir/file — try to remove if empty, else refuse.
    if rmdir "$link" 2>/dev/null; then
        ln -s "$target" "$link"
        log "linked $link -> $target (replaced empty dir)"
        return 0
    fi
    die "$link exists and is non-empty. Refusing to overwrite. Migrate its contents to $target and remove $link before restart."
}
redirect_dir BISHON_DB
redirect_dir logs

# --- 3. Launch uvicorn ------------------------------------------------------
[ -x "$PY" ] || die "$PY not executable. bishon-env may be corrupted."
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
