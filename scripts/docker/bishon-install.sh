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
ACCELERATOR="cuda"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir)    HOST_DIR="$2";    shift 2 ;;
        --release)     RELEASE_TAR="$2"; shift 2 ;;
        --image)       IMAGE_TAR="$2";   shift 2 ;;
        --accelerator) ACCELERATOR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 --host-dir <dir> --release <tar.gz> --image <tar> [--accelerator cuda]
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { echo "[install] $*"; }
die() { echo "[install] FATAL: $*" >&2; exit 1; }

[ -n "$HOST_DIR" ]    || { echo "usage: $0 --host-dir <dir> --release <t> --image <t>" >&2; exit 1; }
[ -n "$RELEASE_TAR" ] || die "--release required"
[ -n "$IMAGE_TAR" ]   || die "--image required"
[ -f "$RELEASE_TAR" ] || die "release tar not found: $RELEASE_TAR"
[ -f "$IMAGE_TAR" ]   || die "image tar not found: $IMAGE_TAR"
command -v docker >/dev/null || die "docker not found on PATH"
command -v curl >/dev/null   || die "curl not found on PATH (needed by start.sh health check)"

HOST_DIR="$(readlink -f "$HOST_DIR")"
log "target host-dir: $HOST_DIR"

# --- 1. Filesystem sanity (避坑指南 #2: SQLite WAL on 9p/NTFS) ----------------
mkdir -p "$HOST_DIR"
case "$HOST_DIR" in
    /mnt/*|/media/*|/run/media/*)
        cat >&2 <<EOF
[install] FATAL: $HOST_DIR looks like a removable / cross-OS mount.
       WSL mounts Windows drives under /mnt/* (9p/drvfs); Linux auto-mounts
       under /media/* or /run/media/* (often cifs/9p). SQLite WAL will fail
       with I/O errors on these filesystems.
       Use an ext4 path inside WSL, e.g. ~/bishon-data or /var/lib/bishon.
EOF
        exit 1 ;;
esac
fs_type="$(df -T "$HOST_DIR" | awk 'NR==2 {print $2}')"
case "$fs_type" in
    9p|drvfs|tmpfs|overlay|smbfs|cifs)
        die "host-dir filesystem is '$fs_type' — not safe for SQLite WAL. Use ext4." ;;
esac
log "filesystem OK ($fs_type)"

# --- 2. Directory skeleton ---------------------------------------------------
mkdir -p "$HOST_DIR"/{bishon-env,bishon,models}
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

[ -d "$TMP/bishon-env/bin" ] || \
    die "release tarball missing bishon-env/bin"
[ -d "$TMP/bishon/bishon_kernel" ] || \
    die "release tarball missing bishon/bishon_kernel"
[ -f "$TMP/bishon/bishon_kernel/bishon_server/dist/bishon/index.html" ] || \
    die "release tarball missing bishon_kernel/bishon_server/dist/bishon/index.html"
[ -d "$TMP/models" ] || \
    die "release tarball missing models/"

rm -rf "$HOST_DIR/bishon-env" "$HOST_DIR/bishon" "$HOST_DIR/models"
mv "$TMP/bishon-env" "$HOST_DIR/bishon-env"
mv "$TMP/bishon"     "$HOST_DIR/bishon"
mv "$TMP/models"     "$HOST_DIR/models"

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
