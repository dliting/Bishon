#!/usr/bin/env bash
# upgrade.sh — upgrade code/models/(optional) env on an installed host.
#
# Usage:
#   bash upgrade.sh --host-dir <dir> --release <new-release.tar.gz>
#
# Overlays new files on top of existing directories (with timestamped backup):
#   - bishon/           (source code)
#   - models/           (model weights)
#   - scripts/          (deploy scripts: start.sh, stop.sh, etc.)
#   - python-env/       (only if the new tarball contains one — rare)
#
# Overlay preserves runtime data (BISHON_DB symlinks, __pycache__, logs)
# that is NOT in the release tarball. Stale source files from old versions
# may remain but are harmless.
#
# NEVER touched:
#   - .env              (user config)
#   - BISHON_DB/        (runtime data)
#   - logs/             (runtime logs)
#   - .image-tag, .accelerator
#
# After upgrade, restart the container: stop.sh && start.sh.

set -euo pipefail

HOST_DIR=""
RELEASE_TAR=""
NODE_TAR=""
PYENV_TAR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir) HOST_DIR="$2";    shift 2 ;;
        --release)  RELEASE_TAR="$2"; shift 2 ;;
        --node)     NODE_TAR="$2";    shift 2 ;;
        --pyenv)    PYENV_TAR="$2";   shift 2 ;;
        -h|--help)
            cat <<EOF
upgrade.sh — Upgrade code/models/scripts on an installed host (in place).

Overlays new files on top of existing directories in <host-dir> from a new
release tarball. Preserves runtime data (BISHON_DB, logs, __pycache__).
Optionally overlays python-env/ via --pyenv. Optionally replaces node-env/
via --node. Never touches .env, BISHON_DB/, logs/, .image-tag, .accelerator.

After upgrade, restart the container: stop.sh && start.sh.

USAGE
  bash $0 --host-dir <dir> --release <new-release.tar.gz> [--node <node-tar>] [--pyenv <pyenv-tar>]

FLAGS
  --host-dir <dir>     Directory created by install.sh.
  --release <tar.gz>   New release tarball (from make-release.sh).
                       Use --skip-pyenv --skip-models in make-release.sh for
                       code-only patches — much smaller tarball.
  --node <tar.gz>      (Optional) Node toolchain tarball from make-release.sh.
                       Atomically replaces node-env/ to upgrade Node or
                       node_modules without rebuilding the docker image.
  --pyenv <tar.gz>     (Optional) Python conda env tarball from make-release.sh.
                       Overlays new files on top of existing python-env/ (with
                       timestamped backup). Required when Python deps change.

EXAMPLES
  bash $0 --host-dir /var/lib/bishon \\
      --release bishon-release-2.2.1.tar.gz

  # Upgrade frontend dependencies only:
  bash $0 --host-dir /var/lib/bishon \\
      --release bishon-release-2.2.1.tar.gz \\
      --node   bishon-node-2.2.1.tar.gz
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

export BISHON_LOG_TAG=upgrade
# shellcheck source=../common/utils.sh
source "$(dirname "$0")/../common/utils.sh"

log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

[ -n "$HOST_DIR" ] || { echo "usage: $0 --host-dir <dir> --release <tar>" >&2; exit 1; }
[ -f "$RELEASE_TAR" ] || die "release tar not found: $RELEASE_TAR"
[ -z "$NODE_TAR" ] || [ -f "$NODE_TAR" ] || die "node tar not found: $NODE_TAR"
[ -z "$PYENV_TAR" ] || [ -f "$PYENV_TAR" ] || die "pyenv tar not found: $PYENV_TAR"
[ -d "$HOST_DIR/bishon" ] || die "$HOST_DIR does not look installed (no bishon/ subdir). Run install.sh first."
# Fail fast if other install artifacts are missing — upgrade cannot repair
# them, and continuing would let start.sh fail later with a confusing
# 'python-env/bin missing' or '.image-tag missing' error.
[ -f "$HOST_DIR/.image-tag" ]     || die "$HOST_DIR/.image-tag missing. Was install.sh ever run?"
[ -d "$HOST_DIR/python-env/bin" ] || die "$HOST_DIR/python-env/bin missing. Upgrade cannot repair a broken env; re-run install.sh."

HOST_DIR="$(readlink -f "$HOST_DIR")"
TS="$(date +%Y%m%d-%H%M%S)"

# Pre-flight: check available disk space. The overlay approach backs up each
# directory before overlaying, so peak usage = current size + backup size +
# tarball extraction. On a 40 GB minimum disk this can be tight.
MIN_AVAIL=5
[ -n "$PYENV_TAR" ] && MIN_AVAIL=10
avail_gb="$(df -P "$HOST_DIR" | awk 'NR==2 {printf "%.0f", $4/1024/1024}')"
if [ "$avail_gb" -lt "$MIN_AVAIL" ]; then
    die "Only ${avail_gb} GB free on $HOST_DIR — need at least ${MIN_AVAIL} GB for upgrade backup. Free space or use a src-only release."
fi

# Same-FS mktemp so `mv` is atomic (see install.sh for rationale).
TMP_DIR="$(mktemp -d -p "$HOST_DIR" .tmp.upgrade.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "extracting $RELEASE_TAR ..."
tar -xzf "$RELEASE_TAR" -C "$TMP_DIR"

# Snapshot what's in the tarball BEFORE we move things out of TMP_DIR.
# These are information-only (consumed by the summary printout at the bottom).
[ -d "$TMP_DIR/bishon" ]     && REPLACED_BISHON="yes" || REPLACED_BISHON="no"
[ -d "$TMP_DIR/models" ]     && REPLACED_MODELS="yes" || REPLACED_MODELS="no"
[ -d "$TMP_DIR/scripts" ]    && REPLACED_SCRIPTS="yes" || REPLACED_SCRIPTS="no"

# Directory replace helper:
#   1. Back up current directory (full copy, preserves all runtime data)
#   2. Overlay new files on top of current directory (cp -a)
#
# Why overlay (cp into existing) instead of swap (mv away, mv new in):
#   - Runtime data lives inside bishon/ as symlinks (BISHON_DB, logs) and
#     caches (__pycache__).  These are NOT in the release tarball.
#   - Overlay preserves them: new source files overwrite old ones, runtime
#     data stays because the tarball doesn't contain files with those names.
#   - Swap would require a "restore runtime data" step that's fragile —
#     any missed data type would be lost.
#   - Stale source files from old versions may remain, but they are harmless.
#
# Backups are cleaned up best-effort at the end.  Root-owned __pycache__
# files may prevent deletion — such backups are reported with a sudo command.
replace_dir() {
    local name="$1"
    local new="$TMP_DIR/$name"
    local cur="$HOST_DIR/$name"
    local old="$HOST_DIR/$name.old.$TS"
    [ -d "$new" ] || return 0

    # Step 1: Full backup of current directory.
    if [ -d "$cur" ]; then
        cp -a "$cur" "$old"
        STALE_BACKUPS+=("$old")
    fi

    # Step 2: Overlay new files on top of current directory.
    # cp -a preserves permissions, symlinks, and timestamps.
    # Files in the tarball overwrite old ones; files NOT in the tarball
    # (runtime symlinks, __pycache__) are preserved.
    cp -a "$new/." "$cur/"

    log "replaced $name/"
}

STALE_BACKUPS=()
STALE_FAILED=()

replace_dir "bishon"
replace_dir "models"
replace_dir "scripts"

# --- python-env from separate tarball (optional) ----------------------------
PYENV_REPLACED="no"
if [ -n "$PYENV_TAR" ]; then
    log "upgrading python-env from $PYENV_TAR"
    TMP_PYENV="$(mktemp -d -p "$HOST_DIR" .tmp.pyenv.XXXXXX)"
    tar -xzf "$PYENV_TAR" -C "$TMP_PYENV"
    [ -d "$TMP_PYENV/python-env" ] || { rm -rf "$TMP_PYENV"; die "pyenv tarball did not produce python-env/ directory"; }
    # Overlay: new files overwrite old, runtime data preserved.
    if [ -d "$HOST_DIR/python-env" ]; then
        OLD_PYENV="$HOST_DIR/python-env.old.$TS"
        cp -a "$HOST_DIR/python-env" "$OLD_PYENV"
        STALE_BACKUPS+=("$OLD_PYENV")
    else
        mkdir -p "$HOST_DIR/python-env"
    fi
    cp -a "$TMP_PYENV/python-env/." "$HOST_DIR/python-env/"
    rm -rf "$TMP_PYENV"
    PYENV_REPLACED="yes"
    log "python-env replaced"
    log "NOTE: If the image's miniconda3 base version changed since install, rebuild the image too."
fi

# --- Best-effort cleanup of old backups --------------------------------------
# __pycache__ files created by root inside Docker may be undeletable by the
# current user.  Collect the ones we can't remove and tell the operator.
for old_dir in "${STALE_BACKUPS[@]+"${STALE_BACKUPS[@]}"}"; do
    if ! rm -rf "$old_dir" 2>/dev/null; then
        STALE_FAILED+=("$old_dir")
    fi
done

# CRLF guard for freshly-extracted shell scripts — same rationale as install.sh.
if [ -d "$HOST_DIR/bishon/docker" ]; then
    log "normalizing line endings on bishon/docker/**/*.sh"
    find "$HOST_DIR/bishon/docker" -name '*.sh' -type f -exec sed -i 's/\r$//' {} +
    chmod +x "$HOST_DIR/bishon/docker/"*.sh 2>/dev/null || true
    [ -d "$HOST_DIR/bishon/docker/entrypoint_lib" ] && \
        chmod +x "$HOST_DIR/bishon/docker/entrypoint_lib/"*.sh 2>/dev/null || true
fi
if [ -d "$HOST_DIR/scripts" ]; then
    log "normalizing line endings on scripts/**/*.sh"
    find "$HOST_DIR/scripts" -name '*.sh' -type f -exec sed -i 's/\r$//' {} +
    chmod +x "$HOST_DIR/scripts/docker/"*.sh "$HOST_DIR/scripts/bare-metal/"*.sh "$HOST_DIR/scripts/common/"*.sh 2>/dev/null || true
fi

# --- Node toolchain (optional, swap replace) ----------------------------------
# --node <tar> replaces $HOST_DIR/node-env/ entirely. Unlike bishon/, node-env
# has no runtime data to preserve, so swap (mv) is simpler and cleaner.
NODE_REPLACED="not requested"
if [ -n "$NODE_TAR" ]; then
    log "upgrading node-env from $NODE_TAR"
    TMP_NODE="$(mktemp -d -p "$HOST_DIR" .tmp.node.XXXXXX)"
    tar -xzf "$NODE_TAR" -C "$TMP_NODE"
    [ -d "$TMP_NODE/node-env" ] || { rm -rf "$TMP_NODE"; die "node tarball did not produce a node-env/ directory"; }
    OLD_NODE="$HOST_DIR/node-env.old.$TS"
    [ -d "$HOST_DIR/node-env" ] && mv "$HOST_DIR/node-env" "$OLD_NODE"
    mv "$TMP_NODE/node-env" "$HOST_DIR/node-env"
    rm -rf "$TMP_NODE"
    # Best-effort cleanup of old node-env backup.
    [ -d "$OLD_NODE" ] && rm -rf "$OLD_NODE" 2>/dev/null || true
    log "node-env replaced"
    NODE_REPLACED="yes"
fi

cat <<EOF
[upgrade] Done. Upgraded to: $HOST_DIR

What was replaced:
   bishon/         $REPLACED_BISHON
   models/         $REPLACED_MODELS
   scripts/        $REPLACED_SCRIPTS
   python-env/     $PYENV_REPLACED
   node-env/       $NODE_REPLACED

Preserved (NEVER touched):
   .env, BISHON_DB/, logs/, .image-tag, .accelerator

Next step — restart the container:
   bash $HOST_DIR/scripts/docker/stop.sh  --host-dir $HOST_DIR
   bash $HOST_DIR/scripts/docker/start.sh --host-dir $HOST_DIR
EOF

# Report any stale backups that could not be deleted (root-owned __pycache__).
if [ ${#STALE_FAILED[@]} -gt 0 ]; then
    cat <<EOF

WARNING: ${#STALE_FAILED[@]} backup dir(s) could not be deleted (root-owned files).
Clean up with:
  sudo rm -rf ${STALE_FAILED[*]}
EOF
fi
