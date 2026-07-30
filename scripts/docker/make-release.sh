#!/usr/bin/env bash
# make-release.sh — assemble the offline release bundle for Bishon V2.
#
# Produces under <repo-root>/dist/:
#   bishon-release-<version>.tar.gz    — source + python-env + models + scripts + .env.example
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
# the baked-in .so files in python-env will fail to load in the container.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

VERSION=""
CONDA_ROOT="${CONDA_ROOT:-/opt/miniconda3}"
SRC_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    VERSION="$2";    shift 2 ;;
        --conda-root) CONDA_ROOT="$2"; shift 2 ;;
        --src-only)   SRC_ONLY=true;   shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--version <ver>] [--conda-root /opt/miniconda3] [--src-only]

  --version <ver>      Image and release tarball version, e.g. 2.1.0.
                       Default: read from VERSION file in repo root.
  --conda-root <path>  Path to miniconda3 installation (def: /opt/miniconda3).
  --src-only           Package source + scripts only; skip python-env, models,
                       and the docker image tar. Fast (~5s) for quick publish
                       testing when only code changed.

Outputs (under dist/):
  bishon-release-<ver>.tar.gz        source + env + models + scripts
  bishon-models-<ver>.tar.gz         models only (for install/upgrade reuse)
  bishon-cuda-image-<ver>.tar        docker save tarball
  bishon-release-<ver>.tar.gz.sha256 checksum file
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Default VERSION from file if not passed on CLI (matches bishon-build.sh).
if [ -z "$VERSION" ]; then
    VERSION_FILE="$REPO_ROOT/VERSION"
    [ -f "$VERSION_FILE" ] || { echo "FATAL: $VERSION_FILE missing and --version not given" >&2; exit 1; }
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    [ -n "$VERSION" ] || { echo "FATAL: VERSION file is empty" >&2; exit 1; }
fi

ENV_SRC="$CONDA_ROOT/envs/bishon"
DIST="$REPO_ROOT/dist/release-$VERSION"
# All tarballs live inside the bundle dir so the operator copies one directory
# and everything (entry script + tarballs + checksums) is in one place.
DIST_TGZ="$DIST/bishon-release-$VERSION.tar.gz"
MODELS_TGZ="$DIST/bishon-models-$VERSION.tar.gz"
IMAGE_TAR="$DIST/bishon-cuda-image-$VERSION.tar"
IMAGE_TAG="bishon-cuda:$VERSION"

export BISHON_LOG_TAG=release
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# --- 0. Pre-flight checks (delegates to scripts/docker/preflight.sh) ---------
PREFLIGHT_ARGS=(--version "$VERSION")
$SRC_ONLY && PREFLIGHT_ARGS+=(--src-only)
bash "$(dirname "$0")/preflight.sh" "${PREFLIGHT_ARGS[@]}" || \
    die "preflight failed. Fix the issues above before running make-release.sh."

# --- 1. Stage directory ------------------------------------------------------

log "staging at $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"
mkdir -p "$REPO_ROOT/dist"

# --- 2. python-env (one env, slim) — skipped in --src-only ------------------
if $SRC_ONLY; then
    log "--src-only: skipping python-env"
    mkdir -p "$DIST/python-env"  # empty placeholder so tarball has the dir
else
    log "copying python-env (~$(du -sh "$ENV_SRC" | cut -f1))"
    rsync -a \
        --exclude '__pycache__' \
        --exclude '*.pyc' \
        --exclude '*.pyo' \
        "$ENV_SRC/" "$DIST/python-env/"
fi

# --- 3. Source code (MANIFEST-driven) ----------------------------------------
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
while IFS= read -r path; do
    src="$REPO_ROOT/$path"
    [ -e "$src" ] || die "MANIFEST references missing path: '$path'"
    dest_parent="$DIST/bishon/$(dirname "$path")"
    mkdir -p "$dest_parent"
    rsync -a "${RSYNC_EXCLUDES[@]}" "$src" "$dest_parent/"
    shipped=$((shipped + 1))
done < <(bishon_parse_manifest "$MANIFEST")
[ "$shipped" -gt 0 ] || die "MANIFEST produced zero staged paths. Is the file empty?"

# --- 4. Models — separate tarball (not in main release) ----------------------
# Models (~2.5 GB) change infrequently; shipping them in the main tarball
# forces every deploy to download them. Instead, produce a standalone
# models tarball that install.sh --models can optionally consume.
if $SRC_ONLY; then
    log "--src-only: skipping models"
else
    log "copying models (~$(du -sh "$REPO_ROOT/models" 2>/dev/null | cut -f1 || echo '?'))"
    mkdir -p "$DIST/models"
    rsync -a --exclude '.git' "$REPO_ROOT/models/" "$DIST/models/"
    log "creating $MODELS_TGZ"
    tar -czf "$MODELS_TGZ" -C "$DIST" models
    (cd "$(dirname "$MODELS_TGZ")" && sha256sum "$(basename "$MODELS_TGZ")" > "$(basename "$MODELS_TGZ").sha256")
fi

# --- 5. Deploy bundle layout (self-contained, drop-in deployable) ------------
# The operator copies the whole dist/release-<ver>/ directory and runs
#   bash deploy.sh
# from inside it. No need to remember script names, paths, or flags.
mkdir -p "$DIST/scripts"
cp -a "$REPO_ROOT/scripts/docker/." "$DIST/scripts/"
rm -f "$DIST/scripts/deploy-entry-wrapper.sh.in"     # template, not needed at runtime

# Render the one-line entry point at bundle root.
cat > "$DIST/deploy.sh" <<'DEPLOY_SH'
#!/usr/bin/env bash
# deploy.sh — Bishon V2 deployment entry point.
# Run from within the deploy bundle directory:
#   bash deploy.sh
# The wizard auto-detects bundle location and finds release/image/models
# tarballs in the same directory.
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/bishon-deploy.sh "$@"
DEPLOY_SH

cp "$REPO_ROOT/.env.example" "$DIST/"

# --- 6. Main tarball ---------------------------------------------------------
# Exclude other bundle artifacts (models tar, image tar, existing release tar)
# so the main tarball carries only source+env+scripts.
log "creating $DIST_TGZ (~this step is slow due to gzip)"
tar -czf "$DIST_TGZ" -C "$DIST" \
    --exclude 'bishon-models-*.tar.gz' \
    --exclude 'bishon-cuda-image-*.tar' \
    --exclude 'bishon-release-*.tar.gz' \
    --exclude 'bishon-release-*.tar.gz.sha256' \
    .
(cd "$(dirname "$DIST_TGZ")" && sha256sum "$(basename "$DIST_TGZ")" > "$(basename "$DIST_TGZ").sha256")

# --- 7. Image tar (skipped in --src-only) ------------------------------------
if $SRC_ONLY; then
    log "--src-only: skipping docker image tar"
else
    log "exporting image to $IMAGE_TAR (docker save)"
    docker save "$IMAGE_TAG" -o "$IMAGE_TAR"
fi

# --- 8. Summary --------------------------------------------------------------
log "done. Artifacts:"
log "  $DIST_TGZ       ($(du -h "$DIST_TGZ" | cut -f1))"
log "  $DIST_TGZ.sha256"
if ! $SRC_ONLY; then
    log "  $MODELS_TGZ     ($(du -h "$MODELS_TGZ" | cut -f1))"
    log "  $MODELS_TGZ.sha256"
    log "  $IMAGE_TAR      ($(du -h "$IMAGE_TAR" | cut -f1))"
fi
log ""
log ""
log "Distribute the whole directory to the deploy host:"
log "  $DIST"
log "On the deploy host, cd into it and run:"
log "  bash deploy.sh"
