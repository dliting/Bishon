#!/usr/bin/env bash
# install.sh — first-time install of Bishon V2 on a deploy host.
#
# Usage:
#   bash install.sh \
#       --host-dir <dir>          # where state lives (must be ext4 in WSL/Linux)
#       --release <release.tar.gz>
#       --image <image.tar>        # from docker save
#       [--accelerator cuda]       # cuda (default) | ascend (future)
#
# Idempotent: re-running overwrites code/env/models but PRESERVES:
#   - .env (only created if missing)
#   - BISHON_DB/  (all runtime data)
#   - logs/
# For an in-place code-only upgrade use upgrade.sh instead.

set -euo pipefail

HOST_DIR=""
RELEASE_TAR=""
IMAGE_TAR=""
MODELS_TAR=""
NODE_TAR=""
PYENV_TAR=""
ACCELERATOR="cuda"
IMAGE_SOURCE="load"     # load | pull | existing
IMAGE_REF=""            # used when IMAGE_SOURCE=pull: e.g. bishon-cuda:2.1.0
REGISTRY="ghcr"         # ghcr | aliyun | <custom-url>
TAG=""                  # image tag, default reads VERSION

# Well-known registries (used when --registry is one of the short names).
REGISTRY_GHCR="ghcr.io/dliting"
REGISTRY_ALIYUN="crpi-cpr1xsemy1pzwjoc.cn-beijing.personal.cr.aliyuncs.com/dliting"
REGISTRY_ALIYUN_VPC="crpi-cpr1xsemy1pzwjoc-vpc.cn-beijing.personal.cr.aliyuncs.com/dliting"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir)     HOST_DIR="$2";    shift 2 ;;
        --release)      RELEASE_TAR="$2"; shift 2 ;;
        --image)        IMAGE_TAR="$2";   shift 2 ;;
        --models)       MODELS_TAR="$2";  shift 2 ;;
        --node)         NODE_TAR="$2";    shift 2 ;;
        --pyenv)        PYENV_TAR="$2";   shift 2 ;;
        --accelerator)  ACCELERATOR="$2"; shift 2 ;;
        --pull)         IMAGE_SOURCE="pull"; shift ;;
        --image-source) IMAGE_SOURCE="$2"; shift 2 ;;
        --image-ref)    IMAGE_REF="$2";   shift 2 ;;
        --tag)          TAG="$2";         shift 2 ;;
        --registry)     REGISTRY="$2";    shift 2 ;;
        --vpc)          REGISTRY="aliyun-vpc"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 --host-dir <dir> (--image <tar> | --pull | --image-source existing) \
          --release <tar> --pyenv <tar>
          [--models <tar.gz>] [--node <tar.gz>] [--accelerator cuda] [--tag <ver>]

Note: --release and --pyenv are ALWAYS required for first-time install.
  --release carries the source code + scripts.
  --pyenv carries the Python conda env (cannot be obtained from a registry pull).

Image source modes:
  --image <tar>            Load image from a local docker save tarball (default).
  --pull                   Pull image from a remote registry (online).
  --image-source existing  Image already loaded/pulled; skip image step entirely.

When --pull is used:
  --registry <r>    ghcr (default) | aliyun | aliyun-vpc | <full-registry-url>
  --tag <ver>       Image tag. Default: read from VERSION in script dir.

Other:
  --host-dir <dir>     Where state lives (must be ext4 / non-9p filesystem).
  --models <tar.gz>    (Optional) Models tarball from make-release.sh.
  --node <tar.gz>      (Optional) Node toolchain tarball from make-release.sh.
                       Enables frontend hot-rebuild at container start.
  --pyenv <tar.gz>     (Required) Python conda env tarball from make-release.sh.
  --accelerator <acc>  cuda (default) | ascend (future).
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=install
# shellcheck source=../common/utils.sh
source "$(dirname "$0")/../common/utils.sh"

# Local aliases so existing `log`/`die` call sites work unchanged.
log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# Validate args based on image source mode.
[ -n "$HOST_DIR" ]    || { echo "usage: $0 --host-dir <dir> ..." >&2; exit 1; }
[ -n "$RELEASE_TAR" ] || die "--release required"
[ -f "$RELEASE_TAR" ] || die "release tar not found: $RELEASE_TAR"
[ -z "$MODELS_TAR" ] || [ -f "$MODELS_TAR" ] || die "models tar not found: $MODELS_TAR"
[ -z "$NODE_TAR"   ] || [ -f "$NODE_TAR"   ] || die "node tar not found: $NODE_TAR"
[ -z "$PYENV_TAR"  ] || [ -f "$PYENV_TAR"  ] || die "pyenv tar not found: $PYENV_TAR"

case "$IMAGE_SOURCE" in
    load)
        [ -n "$IMAGE_TAR" ]   || die "--image <tar> required (or use --pull / --image-source existing)"
        [ -f "$IMAGE_TAR" ]   || die "image tar not found: $IMAGE_TAR"
        ;;
    pull)
        : # IMAGE_TAR not needed; registry/tag determine the image ref.
        ;;
    existing)
        : # caller has already docker pulled/loaded the image; just verify it exists locally
        ;;
    *) die "unknown --image-source value: $IMAGE_SOURCE (use load|pull|existing)" ;;
esac

command -v docker >/dev/null || die "docker not found on PATH"
command -v curl >/dev/null   || die "curl not found on PATH (needed by start.sh health check)"

# Resolve registry URL from short name.
case "$REGISTRY" in
    ghcr)       REGISTRY_URL="$REGISTRY_GHCR" ;;
    aliyun)     REGISTRY_URL="$REGISTRY_ALIYUN" ;;
    aliyun-vpc) REGISTRY_URL="$REGISTRY_ALIYUN_VPC" ;;
    *)          REGISTRY_URL="$REGISTRY" ;;   # treat as full URL
esac

# Default tag from VERSION file if not specified (used by --pull and --existing).
if [ -z "$TAG" ] && [ "$IMAGE_SOURCE" != "load" ]; then
    VERSION_FILE="$(cd "$(dirname "$0")/.." && pwd)/VERSION"
    if [ -f "$VERSION_FILE" ]; then
        TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
    fi
fi

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

# --- 3. Image acquisition ----------------------------------------------------
case "$IMAGE_SOURCE" in
    load)
        log "loading image from $IMAGE_TAR ..."
        IMAGE_TAG="$(docker load -i "$IMAGE_TAR" | sed -n 's/^Loaded image: //p' | head -1)"
        [ -n "$IMAGE_TAG" ] || die "could not parse image tag from docker load output"
        log "image: $IMAGE_TAG"
        ;;
    pull)
        [ -n "$TAG" ] || die "--tag required with --pull (or place a VERSION file alongside scripts/)"
        IMAGE_TAG="$REGISTRY_URL/bishon-cuda:$TAG"
        log "pulling image: $IMAGE_TAG"
        docker pull "$IMAGE_TAG" || die "docker pull failed (registry may require login: docker login $REGISTRY_URL)"
        # Tag it locally as bishon-cuda:<tag> so start.sh's .image-tag mechanism works uniformly.
        LOCAL_TAG="bishon-cuda:$TAG"
        docker tag "$IMAGE_TAG" "$LOCAL_TAG" || die "failed to tag pulled image as $LOCAL_TAG"
        IMAGE_TAG="$LOCAL_TAG"
        log "image: $IMAGE_TAG (tagged from $REGISTRY_URL)"
        ;;
    existing)
        [ -n "$TAG" ] || die "--tag required with --image-source existing (or place a VERSION file)"
        IMAGE_TAG="bishon-cuda:$TAG"
        docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || \
            die "image $IMAGE_TAG not present locally. Run docker pull first or use --pull / --image <tar>."
        log "image: $IMAGE_TAG (already present)"
        ;;
esac

# --- 4. Extract release tarball to a temp dir, then atomically move ----------
# mktemp -d -p "$HOST_DIR" guarantees the temp dir is on the SAME filesystem as
# the final destination, so `mv` is rename(2) atomic. A generic `mktemp -d`
# might land on /tmp (often tmpfs), forcing mv to fall back to copy+unlink,
# which is non-atomic and can leave a half-installed state on interruption.
TMP="$(mktemp -d -p "$HOST_DIR" .tmp.install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

log "extracting $RELEASE_TAR ..."
tar -xzf "$RELEASE_TAR" -C "$TMP"

[ -d "$TMP/bishon/bishon_kernel" ] || \
    die "release tarball missing bishon/bishon_kernel"
[ -f "$TMP/bishon/bishon_kernel/bishon_server/dist/bishon/index.html" ] || \
    die "release tarball missing bishon_kernel/bishon_server/dist/bishon/index.html"
if ! grep -qP 'src="/bishon/assets/|href="/bishon/assets/' "$TMP/bishon/bishon_kernel/bishon_server/dist/bishon/index.html" 2>/dev/null; then
    die "release tarball frontend dist has wrong base path (assets do not start with /bishon/assets/). Rebuild with VITE_APP_WEB_PREFIX=/bishon."
fi

rm -rf "$HOST_DIR/bishon"
mv "$TMP/bishon"     "$HOST_DIR/bishon"

# --- 4b. python-env: separate tarball (required) ----------------------------
if [ -z "$PYENV_TAR" ]; then
    die "python-env required for first-time install. Use --pyenv <tar>."
fi
log "extracting python-env from $PYENV_TAR"
tar -xzf "$PYENV_TAR" -C "$HOST_DIR"
[ -d "$HOST_DIR/python-env/bin" ] || \
    die "pyenv tarball did not produce python-env/bin directory"

# CRLF guard: if the release tarball was made on Windows or git checked out
# with CRLF, bishon/docker/*.sh would fail in the container with
# '/usr/bin/env: bash\r': No such file. Normalize before any docker run.
if [ -d "$HOST_DIR/bishon/docker" ]; then
    log "normalizing line endings on bishon/docker/**/*.sh"
    find "$HOST_DIR/bishon/docker" -name '*.sh' -type f -exec sed -i 's/\r$//' {} +
    chmod +x "$HOST_DIR/bishon/docker/"*.sh 2>/dev/null || true
    [ -d "$HOST_DIR/bishon/docker/entrypoint_lib" ] && \
        chmod +x "$HOST_DIR/bishon/docker/entrypoint_lib/"*.sh 2>/dev/null || true
fi

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
    log "  tar -xzf bishon-models-${TAG:-unknown}.tar.gz -C $HOST_DIR"
fi

# --- Node toolchain: optional separate tarball for frontend hot-rebuild -------
# install.sh --node <tar> extracts bishon-node-<ver>.tar.gz to $HOST_DIR/node-env/.
# entrypoint.sh then binds it via symlink + PATH. If absent, the container starts
# normally but skips frontend hot-rebuild (dist must be pre-built by make-release).
rm -rf "$HOST_DIR/node-env"
if [ -n "$NODE_TAR" ]; then
    log "extracting node-env from $NODE_TAR"
    tar -xzf "$NODE_TAR" -C "$HOST_DIR"
    [ -d "$HOST_DIR/node-env" ] || die "node tarball did not produce a node-env/ directory"
    log "node-env installed to $HOST_DIR/node-env"
elif [ ! -d "$HOST_DIR/node-env" ]; then
    log "node-env not installed (frontend hot-rebuild disabled at container start)."
    log "  Install with --node bishon-node-${TAG:-unknown}.tar.gz to enable."
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
echo "bridge" > "$HOST_DIR/.network"

# --- 7. Next steps -----------------------------------------------------------
cat <<EOF
[install] Done. Installed to: $HOST_DIR
   image:       $IMAGE_TAG
   accelerator: $ACCELERATOR

Next steps:
  1. Edit $HOST_DIR/.env — set OPENAI_API_BASE and EMBEDDING_API_BASE.
     - Docker bridge mode: use Docker bridge IP (e.g. http://172.17.0.1:8000/v1)
     - Docker host mode (--network host): localhost works
  2. Start the service:
       bash $HOST_DIR/scripts/docker/start.sh --host-dir $HOST_DIR
     Add --network host if LLM/Embedding services run on the same host.
EOF
if [ -z "$NODE_TAR" ] && [ ! -d "$HOST_DIR/node-env" ]; then
    cat <<EOF
  3. (Optional) Install node-env to enable frontend hot-rebuild at container start:
       bash $0 --host-dir $HOST_DIR --node bishon-node-${TAG:-unknown}.tar.gz
     (replaces existing install; preserves .env, BISHON_DB/, logs/)
EOF
fi
