#!/usr/bin/env bash
# bishon-publish.sh — upgrade code/models/(optional) env on an installed host.
#
# Usage:
#   bash bishon-publish.sh --host-dir <dir> --release <new-release.tar.gz>
#
# Atomically replaces (with timestamped backup, then deletes the backup):
#   - bishon/           (source code)
#   - models/           (model weights)
#   - bishon-env/       (only if the new tarball contains one — rare)
#
# NEVER touched:
#   - .env              (user config)
#   - BISHON_DB/        (runtime data)
#   - logs/             (runtime logs)
#   - .image-tag, .accelerator
#
# After publish, restart the container: bishon-stop.sh && bishon-start.sh.

set -euo pipefail

HOST_DIR=""
RELEASE_TAR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-dir) HOST_DIR="$2";    shift 2 ;;
        --release)  RELEASE_TAR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 --host-dir <dir> --release <new-release.tar.gz>
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { echo "[publish] $*"; }
die() { echo "[publish] FATAL: $*" >&2; exit 1; }

[ -n "$HOST_DIR" ] || { echo "usage: $0 --host-dir <dir> --release <tar>" >&2; exit 1; }
[ -f "$RELEASE_TAR" ] || die "release tar not found: $RELEASE_TAR"
[ -d "$HOST_DIR/bishon" ] || die "$HOST_DIR does not look installed (no bishon/ subdir). Run bishon-install.sh first."
# Fail fast if other install artifacts are missing — publish cannot repair
# them, and continuing would let bishon-start.sh fail later with a confusing
# 'bishon-env/bin missing' or '.image-tag missing' error.
[ -f "$HOST_DIR/.image-tag" ]     || die "$HOST_DIR/.image-tag missing. Was bishon-install.sh ever run?"
[ -d "$HOST_DIR/bishon-env/bin" ] || die "$HOST_DIR/bishon-env/bin missing. Publish cannot repair a broken env; re-run bishon-install.sh."

HOST_DIR="$(readlink -f "$HOST_DIR")"
TS="$(date +%Y%m%d-%H%M%S)"
# Same-FS mktemp so `mv` is atomic (see bishon-install.sh for rationale).
TMP_DIR="$(mktemp -d -p "$HOST_DIR" .tmp.publish.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "extracting $RELEASE_TAR ..."
tar -xzf "$RELEASE_TAR" -C "$TMP_DIR"

# Snapshot what's in the tarball BEFORE we move things out of TMP_DIR.
# These are information-only (consumed by the summary printout at the bottom).
[ -d "$TMP_DIR/bishon" ]     && REPLACED_BISHON="yes" || REPLACED_BISHON="no"
[ -d "$TMP_DIR/models" ]     && REPLACED_MODELS="yes" || REPLACED_MODELS="no"
[ -d "$TMP_DIR/bishon-env" ] && REPLACED_BISHON_ENV="yes" || REPLACED_BISHON_ENV="no (not in tarball)"

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
    replace_dir "bishon-env"
    log "NOTE: bishon-env replaced. If the image's miniconda3 base version"
    log "      changed since install, rebuild the image too."
}

cat <<EOF
[publish] Done. Upgraded to: $HOST_DIR

What was replaced:
   bishon/         $REPLACED_BISHON
   models/         $REPLACED_MODELS
   bishon-env/     $REPLACED_BISHON_ENV

Preserved (NEVER touched):
   .env, BISHON_DB/, logs/, .image-tag, .accelerator

Next step — restart the container:
   bash $HOST_DIR/scripts/bishon-stop.sh  --host-dir $HOST_DIR
   bash $HOST_DIR/scripts/bishon-start.sh --host-dir $HOST_DIR
EOF
