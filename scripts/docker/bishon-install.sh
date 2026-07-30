#!/usr/bin/env bash
# bishon-install.sh — first-time install of Bishon V2 on a deploy host.
#
# Usage:
#   bash bishon-install.sh \
#       --host-dir <dir>          # where state lives (must be ext4 in WSL/Linux)
#       --release <release.tar.gz>
#       --image <image.tar>        # from docker save
#       [--accelerator cuda]       # cuda (default) | ascend (future)
#
# Idempotent: re-running overwrites code/env/models but PRESERVES:
#   - .env (only created if missing)
#   - BISHON_DB/  (all runtime data)
#   - logs/
# For an in-place code-only upgrade use bishon-publish.sh instead.

set -euo pipefail

HOST_DIR=""
RELEASE_TAR=""
IMAGE_TAR=""
MODELS_TAR=""
ACCELERATOR="cuda"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir)    HOST_DIR="$2";    shift 2 ;;
        --release)     RELEASE_TAR="$2"; shift 2 ;;
        --image)       IMAGE_TAR="$2";   shift 2 ;;
        --models)      MODELS_TAR="$2";  shift 2 ;;
        --accelerator) ACCELERATOR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 --host-dir <dir> --release <tar.gz> --image <tar>
          [--models <tar.gz>] [--accelerator cuda]

  --host-dir <dir>     Where state lives (must be ext4 / non-9p filesystem).
  --release <tar.gz>   Main release tarball (source + env + scripts).
  --image <tar>        Docker image from 'docker save'.
  --models <tar.gz>    (Optional) Models tarball from make-release.sh. Skip
                       to install without models (useful for upgrade when
                       models are unchanged).
  --accelerator <acc>  cuda (default) | ascend (future).
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=install
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# Local aliases so existing `log`/`die` call sites work unchanged.
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

[ -n "$HOST_DIR" ]    || { echo "usage: $0 --host-dir <dir> --release <t> --image <t>" >&2; exit 1; }
[ -n "$RELEASE_TAR" ] || die "--release required"
[ -n "$IMAGE_TAR" ]   || die "--image required"
[ -f "$RELEASE_TAR" ] || die "release tar not found: $RELEASE_TAR"
[ -f "$IMAGE_TAR" ]   || die "image tar not found: $IMAGE_TAR"
[ -z "$MODELS_TAR" ] || [ -f "$MODELS_TAR" ] || die "models tar not found: $MODELS_TAR"
command -v docker >/dev/null || die "docker not found on PATH"
command -v curl >/dev/null   || die "curl not found on PATH (needed by start.sh health check)"

HOST_DIR="$(readlink -f "$HOST_DIR")"
log "target host-dir: $HOST_DIR"

# --- 1. Filesystem sanity (避坑指南 #2: SQLite WAL on 9p/NTFS) ----------------
mkdir -p "$HOST_DIR"
# bishon_validate_host_dir_fs prints the fs_type to stdout on success (saves
# the caller from re-running df -T).
fs_type="$(bishon_validate_host_dir_fs "$HOST_DIR")" || exit 1
log "filesystem OK ($fs_type)"

# --- 2. Directory skeleton ---------------------------------------------------
mkdir -p "$HOST_DIR"/{python-env,bishon,models}
mkdir -p "$HOST_DIR"/BISHON_DB/{faiss,content}
mkdir -p "$HOST_DIR"/logs/{debug_logs,qa_logs}

# --- 3. Load image -----------------------------------------------------------
log "loading image from $IMAGE_TAR ..."
IMAGE_TAG="$(docker load -i "$IMAGE_TAR" | sed -n 's/^Loaded image: //p' | head -1)"
[ -n "$IMAGE_TAG" ] || die "could not parse image tag from docker load output"
log "image: $IMAGE_TAG"

# --- 4. Extract release tarball to a temp dir, then atomically move ----------
# mktemp -d -p "$HOST_DIR" guarantees the temp dir is on the SAME filesystem as
# the final destination, so `mv` is rename(2) atomic. A generic `mktemp -d`
# might land on /tmp (often tmpfs), forcing mv to fall back to copy+unlink,
# which is non-atomic and can leave a half-installed state on interruption.
TMP="$(mktemp -d -p "$HOST_DIR" .tmp.install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

log "extracting $RELEASE_TAR ..."
tar -xzf "$RELEASE_TAR" -C "$TMP"

[ -d "$TMP/python-env/bin" ] || \
    die "release tarball missing python-env/bin"
[ -d "$TMP/bishon/bishon_kernel" ] || \
    die "release tarball missing bishon/bishon_kernel"
[ -f "$TMP/bishon/bishon_kernel/bishon_server/dist/bishon/index.html" ] || \
    die "release tarball missing bishon_kernel/bishon_server/dist/bishon/index.html"

rm -rf "$HOST_DIR/python-env" "$HOST_DIR/bishon"
mv "$TMP/python-env" "$HOST_DIR/python-env"
mv "$TMP/bishon"     "$HOST_DIR/bishon"

# --- Models: optional separate tarball or legacy inline path --------------------
# --models takes priority; if omitted, check the main tarball for a models/ dir
# (backward compat with older releases that shipped models inline). If neither
# is present, install without models — the service runs fine w/o them (Rerank
# can be disabled; OCR will warn at startup).
rm -rf "$HOST_DIR/models"
if [ -n "$MODELS_TAR" ]; then
    log "extracting models from $MODELS_TAR"
    tar -xzf "$MODELS_TAR" -C "$HOST_DIR"
    [ -d "$HOST_DIR/models" ] || die "models tarball did not produce a models/ directory"
elif [ -d "$TMP/models" ]; then
    # Legacy: models bundled in the main tarball.
    mv "$TMP/models" "$HOST_DIR/models"
else
    mkdir -p "$HOST_DIR/models"
    log "no models tarball provided; models/ will be empty."
    log "Install models tarball separately if needed with:"
    log "  tar -xzf bishon-models-$VERSION.tar.gz -C $HOST_DIR"
fi

mkdir -p "$HOST_DIR/scripts"
cp -a "$TMP/scripts/." "$HOST_DIR/scripts/"
cp "$TMP/.env.example" "$HOST_DIR/"

# --- 5. .env (避坑指南 #4 陷阱 1: never overwrite) ---------------------------
if [ ! -f "$HOST_DIR/.env" ]; then
    cp "$HOST_DIR/.env.example" "$HOST_DIR/.env"
    log "initialized .env from .env.example (edit before first start!)"
else
    log ".env already exists — preserved"
fi

# --- 6. Record installed version ---------------------------------------------
echo "$IMAGE_TAG" > "$HOST_DIR/.image-tag"
echo "$ACCELERATOR" > "$HOST_DIR/.accelerator"

# --- 7. Next steps -----------------------------------------------------------
cat <<EOF
[install] Done. Installed to: $HOST_DIR
   image:       $IMAGE_TAG
   accelerator: $ACCELERATOR

Next steps:
  1. Edit $HOST_DIR/.env — set OPENAI_API_BASE and EMBEDDING_API_BASE to
     explicit reachable URLs (NOT host.docker.internal).
  2. Start the service:
       bash $HOST_DIR/scripts/bishon-start.sh --host-dir $HOST_DIR
EOF
