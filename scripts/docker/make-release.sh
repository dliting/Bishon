#!/usr/bin/env bash
# make-release.sh — assemble the offline release bundle for Bishon V2.
#
# Produces under <repo-root>/dist/:
#   bishon-release-<version>.tar.gz    — source + bishon-env + models + scripts + .env.example
#   bishon-cuda-image-<version>.tar    — docker save of bishon-cuda:<version>
#
# Usage:
#   bash scripts/docker/make-release.sh --version 2.1.0 [--conda-root /opt/miniconda3]
#
# Run inside WSL (Ubuntu 22.04) with the bishon conda env already created and
# all Python deps installed. The image must already exist (run bishon-build.sh
# first) — this script refuses to ship a release without its matching image.
#
# Hard constraint: WSL Ubuntu version MUST equal the image base (22.04), or
# the baked-in .so files in bishon-env will fail to load in the container.

set -euo pipefail

VERSION=""
CONDA_ROOT="${CONDA_ROOT:-/opt/miniconda3}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    VERSION="$2";    shift 2 ;;
        --conda-root) CONDA_ROOT="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 --version <ver> [--conda-root /opt/miniconda3]
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
[ -n "$VERSION" ] || { echo "usage: $0 --version <ver>" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_SRC="$CONDA_ROOT/envs/bishon"
DIST="$REPO_ROOT/dist/release-$VERSION"
DIST_TGZ="$REPO_ROOT/dist/bishon-release-$VERSION.tar.gz"
IMAGE_TAR="$REPO_ROOT/dist/bishon-cuda-image-$VERSION.tar"
IMAGE_TAG="bishon-cuda:$VERSION"

log() { echo "[release] $*"; }
die() { echo "[release] FATAL: $*" >&2; exit 1; }

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

# --- 0. Pre-flight checks ----------------------------------------------------

[ -d "$ENV_SRC" ] || \
    die "bishon conda env not found at $ENV_SRC. Create it in WSL first."

# 0a. WSL Ubuntu version must match image base (glibc compat).
WSL_UBUNTU_VER="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}" || echo unknown)"
[ "$WSL_UBUNTU_VER" = "22.04" ] || {
    cat >&2 <<EOF
[release] FATAL: WSL Ubuntu is '${WSL_UBUNTU_VER}' but image base is 22.04.
       The .so files baked into $ENV_SRC would fail to load against the
       container's glibc. Aborting. Build the bishon env on Ubuntu 22.04.
EOF
    exit 1
}

# 0b. bishon env must import all critical deps (avoid shipping a broken env).
"$ENV_SRC/bin/python" - <<'PY' || die "bishon env import check failed (see errors above)."
import sys
required = ("fastapi", "uvicorn", "torch", "faiss", "paddle", "transformers", "langchain")
missing = []
for mod in required:
    try:
        __import__(mod)
    except Exception as e:
        print(f"missing/broken: {mod} ({e})", file=sys.stderr)
        missing.append(mod)
if missing:
    sys.exit(1)
print("env import check OK")
PY

# 0c. Static assets must be present (runtime hard-dependency).
[ -f "$REPO_ROOT/bishon_kernel/bishon_server/dist/bishon/index.html" ] || {
    cat >&2 <<EOF
[release] FATAL: bishon_kernel/bishon_server/dist/bishon/index.html missing.
       Rebuild the frontend and copy output:
         cd front_end && npm ci && npm run build
         cp -r front_end/dist bishon_kernel/bishon_server/
EOF
    exit 1
}

# 0d. Models must contain the OCR weights (Rerank is optional; RERANK_ENABLED
# defaults to false). An empty models/ would silently produce a release that
# crashes on first OCR call.
paddle_dir="$REPO_ROOT/models/paddleocr_models"
[ -d "$paddle_dir" ] || die "$paddle_dir missing."
paddle_subdirs="$(find "$paddle_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
[ "$paddle_subdirs" -ge 4 ] || \
    die "$paddle_dir has $paddle_subdirs subdirs; expected >=4 (det/rec/cls/doc_ori). Download paddleocr_models first."

# 0d. Image must already exist (we will docker save it).
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || \
    die "Image $IMAGE_TAG not found. Run: bishon-build.sh --version $VERSION"

# --- 1. Stage directory ------------------------------------------------------

log "staging at $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

# --- 2. bishon-env (one env, slim) -------------------------------------------
# NOTE: do NOT --exclude 'pip' — it would also drop bin/pip and
# site-packages/pip, breaking in-container pip. The pip *cache* lives outside
# the env (under ~/.cache/pip) and is cleaned separately.
log "copying bishon-env (~$(du -sh "$ENV_SRC" | cut -f1))"
rsync -a \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '*.pyo' \
    "$ENV_SRC/" "$DIST/bishon-env/"

# --- 3. Source code (MANIFEST-driven) ----------------------------------------
# The list of paths that ship lives in release/MANIFEST (explicit opt-in).
# These excludes apply to every manifest entry — they cover build artifacts
# and caches that never belong in a release tarball.
#
# Note: do NOT use --exclude 'dist' — it would also drop
# bishon_kernel/bishon_server/dist/bishon/ (the runtime-mounted frontend
# assets). The step 0c check above guarantees that directory is populated.
MANIFEST="$REPO_ROOT/release/MANIFEST"
[ -f "$MANIFEST" ] || \
    die "release/MANIFEST not found at $MANIFEST. Required to assemble release."

RSYNC_EXCLUDES=(
    --exclude '__pycache__'
    --exclude '*.pyc'
    --exclude '*.pyo'
    --exclude '.pytest_cache'
    --exclude '.ruff_cache'
    --exclude 'node_modules'
    --exclude 'front_end/dist'
    --exclude '.git'
)

log "staging source from MANIFEST ($(wc -l < "$MANIFEST") lines)"
shipped=0
# bishon_parse_manifest drops comments/blanks and trims whitespace; it
# returns paths one per line via stdout. Piping through process substitution
# keeps the surrounding `while` body able to mutate $shipped.
while IFS= read -r path; do
    src="$REPO_ROOT/$path"
    [ -e "$src" ] || die "MANIFEST references missing path: '$path'"

    # Preserve the relative path under $DIST/bishon/. For top-level files
    # dirname=".", for nested paths the parent dir is created.
    dest_parent="$DIST/bishon/$(dirname "$path")"
    mkdir -p "$dest_parent"
    rsync -a "${RSYNC_EXCLUDES[@]}" "$src" "$dest_parent/"
    shipped=$((shipped + 1))
done < <(bishon_parse_manifest "$MANIFEST")
[ "$shipped" -gt 0 ] || die "MANIFEST produced zero staged paths. Is the file empty?"

# --- 4. Models (strip .git to slim) ------------------------------------------
log "copying models (~$(du -sh "$REPO_ROOT/models" 2>/dev/null | cut -f1 || echo '?'))"
rsync -a --exclude '.git' "$REPO_ROOT/models/" "$DIST/models/"

# --- 5. Top-level convenience copies for install.sh --------------------------
# install.sh extracts the tarball then reads scripts/ and .env.example from
# the top level of the tarball (not from inside bishon/) so the operator
# doesn't need to cd anywhere to start install. Keep them in sync with the
# canonical copies under bishon/.
mkdir -p "$DIST/scripts"
cp -a "$REPO_ROOT/scripts/docker/." "$DIST/scripts/"
cp "$REPO_ROOT/.env.example" "$DIST/"

# --- 6. Tarball --------------------------------------------------------------
log "creating $DIST_TGZ (~this step is slow due to gzip)"
mkdir -p "$REPO_ROOT/dist"
tar -czf "$DIST_TGZ" -C "$DIST" .

# --- 7. Image tar ------------------------------------------------------------
log "exporting image to $IMAGE_TAR (docker save)"
docker save "$IMAGE_TAG" -o "$IMAGE_TAR"

# --- 8. Summary --------------------------------------------------------------
log "done. Artifacts:"
log "  $DIST_TGZ   ($(du -h "$DIST_TGZ" | cut -f1))"
log "  $IMAGE_TAR  ($(du -h "$IMAGE_TAR" | cut -f1))"
log ""
log "Distribute both files to the deploy host. Then run bishon-install.sh."
