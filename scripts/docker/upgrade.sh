#!/usr/bin/env bash
# upgrade.sh — upgrade code/models/(optional) env on an installed host.
#
# Usage:
#   bash upgrade.sh --host-dir <dir> --release <new-release.tar.gz>
#
# Atomically replaces (with timestamped backup, then deletes the backup):
#   - bishon/           (source code)
#   - models/           (model weights)
#   - python-env/       (only if the new tarball contains one — rare)
#
# NEVER touched:
#   - .env              (user config)
#   - BISHON_DB/        (runtime data)
#   - logs/             (runtime logs)
#   - .image-tag, .accelerator
#
# After publish, restart the container: stop.sh && start.sh.

set -euo pipefail

HOST_DIR=""
RELEASE_TAR=""
NODE_TAR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir) HOST_DIR="$2";    shift 2 ;;
        --release)  RELEASE_TAR="$2"; shift 2 ;;
        --node)     NODE_TAR="$2";    shift 2 ;;
        -h|--help)
            cat <<EOF
upgrade.sh — Upgrade code/models on an installed host (in place).

Atomically replaces bishon/ (source) and models/ in <host-dir> from a new
release tarball, then optionally python-env/ if the new tarball carries one.
Optionally replaces node-env/ via --node. Never touches .env, BISHON_DB/,
logs/, .image-tag, .accelerator.

After publish, restart the container: stop.sh && start.sh.

USAGE
  bash $0 --host-dir <dir> --release <new-release.tar.gz> [--node <node-tar>]

FLAGS
  --host-dir <dir>     Directory created by install.sh.
  --release <tar.gz>   New release tarball (from make-release.sh).
                       Use --src-only mode in make-release.sh for code-only
                       patches (no env, no models) — much smaller tarball.
  --node <tar.gz>      (Optional) Node toolchain tarball from make-release.sh.
                       Atomically replaces node-env/ to upgrade Node or
                       node_modules without rebuilding the docker image.

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

export BISHON_LOG_TAG=publish
# shellcheck source=../common/utils.sh
source "$(dirname "$0")/../common/utils.sh"

log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

[ -n "$HOST_DIR" ] || { echo "usage: $0 --host-dir <dir> --release <tar>" >&2; exit 1; }
[ -f "$RELEASE_TAR" ] || die "release tar not found: $RELEASE_TAR"
[ -z "$NODE_TAR" ] || [ -f "$NODE_TAR" ] || die "node tar not found: $NODE_TAR"
[ -d "$HOST_DIR/bishon" ] || die "$HOST_DIR does not look installed (no bishon/ subdir). Run install.sh first."
# Fail fast if other install artifacts are missing — publish cannot repair
# them, and continuing would let start.sh fail later with a confusing
# 'python-env/bin missing' or '.image-tag missing' error.
[ -f "$HOST_DIR/.image-tag" ]     || die "$HOST_DIR/.image-tag missing. Was install.sh ever run?"
[ -d "$HOST_DIR/python-env/bin" ] || die "$HOST_DIR/python-env/bin missing. Publish cannot repair a broken env; re-run install.sh."

HOST_DIR="$(readlink -f "$HOST_DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
# Same-FS mktemp so `mv` is atomic (see install.sh for rationale).
TMP_DIR="$(mktemp -d -p "$HOST_DIR" .tmp.publish.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "extracting $RELEASE_TAR ..."
tar -xzf "$RELEASE_TAR" -C "$TMP_DIR"

# Snapshot what's in the tarball BEFORE we move things out of TMP_DIR.
# These are information-only (consumed by the summary printout at the bottom).
[ -d "$TMP_DIR/bishon" ]     && REPLACED_BISHON="yes" || REPLACED_BISHON="no"
[ -d "$TMP_DIR/models" ]     && REPLACED_MODELS="yes" || REPLACED_MODELS="no"
[ -d "$TMP_DIR/python-env" ] && REPLACED_BISHON_ENV="yes" || REPLACED_BISHON_ENV="no (not in tarball)"

# Atomic replace helper: mv current aside, mv new in, then delete the backup.
# Caller must check existence of $TMP_DIR/$name first; we assert here.
replace_dir() {
    local name="$1"
    local new="$TMP_DIR/$name"
    local cur="$HOST_DIR/$name"
    local old="$HOST_DIR/$name.old.$TS"
    [ -d "$new" ] || return 0
    [ -d "$cur" ] && mv "$cur" "$old"
    mv "$new" "$cur"
    rm -rf "$old"
    log "replaced $name/"
}

replace_dir "bishon"
replace_dir "models"
[ "$REPLACED_BISHON_ENV" = "yes" ] && {
    replace_dir "python-env"
    log "NOTE: python-env replaced. If the image's miniconda3 base version"
    log "      changed since install, rebuild the image too."
}

# CRLF guard for freshly-extracted bishon/docker/*.sh — same rationale as install.sh.
if [ -d "$HOST_DIR/bishon/docker" ]; then
    log "normalizing line endings on bishon/docker/**/*.sh"
    find "$HOST_DIR/bishon/docker" -name '*.sh' -type f -exec sed -i 's/\r$//' {} +
    chmod +x "$HOST_DIR/bishon/docker/"*.sh 2>/dev/null || true
    [ -d "$HOST_DIR/bishon/docker/entrypoint_lib" ] && \
        chmod +x "$HOST_DIR/bishon/docker/entrypoint_lib/"*.sh 2>/dev/null || true
fi

# --- Node toolchain (optional, atomic replace) -------------------------------
# --node <tar> extracts bishon-node-<ver>.tar.gz and atomically replaces
# $HOST_DIR/node-env/. Use to upgrade Node.js or npm packages without
# rebuilding the docker image or re-running install.sh.
NODE_REPLACED="not requested"
if [ -n "$NODE_TAR" ]; then
    log "upgrading node-env from $NODE_TAR"
    TMP_NODE="$(mktemp -d -p "$HOST_DIR" .tmp.node.XXXXXX)"
    tar -xzf "$NODE_TAR" -C "$TMP_NODE"
    [ -d "$TMP_NODE/node-env" ] || { rm -rf "$TMP_NODE"; die "node tarball did not produce a node-env/ directory"; }
    OLD_NODE="$HOST_DIR/node-env.old.$TS"
    [ -d "$HOST_DIR/node-env" ] && mv "$HOST_DIR/node-env" "$OLD_NODE"
    mv "$TMP_NODE/node-env" "$HOST_DIR/node-env"
    rm -rf "$TMP_NODE" "$OLD_NODE"
    log "node-env replaced"
    NODE_REPLACED="yes"
fi

cat <<EOF
[publish] Done. Upgraded to: $HOST_DIR

What was replaced:
   bishon/         $REPLACED_BISHON
   models/         $REPLACED_MODELS
   python-env/     $REPLACED_BISHON_ENV
   node-env/       $NODE_REPLACED

Preserved (NEVER touched):
   .env, BISHON_DB/, logs/, .image-tag, .accelerator

Next step — restart the container:
   bash $HOST_DIR/scripts/docker/stop.sh  --host-dir $HOST_DIR
   bash $HOST_DIR/scripts/docker/start.sh --host-dir $HOST_DIR
EOF
