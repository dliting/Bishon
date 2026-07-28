#!/usr/bin/env bash
# Common helpers shared across bishon docker scripts.
#
# Source this file from any bishon-*.sh:
#   # shellcheck source=lib/common.sh
#   source "$(dirname "$0")/lib/common.sh"
#
# Design:
#   - No side effects at source time.
#   - Each function prefixed with `bishon_` to avoid collisions.
#   - Pure where possible (parse, validate) so they can be unit-tested.

# Print an informational message to stdout. Caller's [tag] prefix is set by
# BISHON_LOG_TAG (default: "bishon"). Override per-script:
#   BISHON_LOG_TAG=install source lib/common.sh
bishon_log() {
    printf '[%s] %s\n' "${BISHON_LOG_TAG:-bishon}" "$*"
}

# Print a fatal message to stderr and exit non-zero.
bishon_die() {
    printf '[%s] FATAL: %s\n' "${BISHON_LOG_TAG:-bishon}" "$*" >&2
    exit 1
}

# Parse a manifest file: each non-comment, non-blank line is treated as a path.
# Outputs paths to stdout (one per line). Returns non-zero if file missing.
#
# Comment rule: a line is a comment if its first non-whitespace char is '#'.
# Trailing inline comments (`path  # note`) are NOT supported — put notes on
# a separate line above the path.
bishon_parse_manifest() {
    local manifest="$1"
    [ -f "$manifest" ] || return 1
    local raw path
    while IFS= read -r raw || [ -n "$raw" ]; do
        [[ "$raw" =~ ^[[:space:]]*# ]] && continue
        path="$(printf '%s' "$raw" | xargs)"   # trim surrounding whitespace
        [ -z "$path" ] && continue
        printf '%s\n' "$path"
    done < "$manifest"
}

# Validate that HOST_DIR is on a filesystem safe for SQLite WAL.
# Returns 0 if safe; returns 1 with a human-readable message on stderr if not.
#
# Checks two things, in order:
#   1. Path doesn't live under well-known 9p/drvfs mount roots (/mnt/*, /media/*,
#      /run/media/*). These are almost always unsafe.
#   2. df -T doesn't report a known-incompatible fs type.
bishon_validate_host_dir_fs() {
    local host_dir="$1"
    [ -n "$host_dir" ] || { echo "FATAL: validate_host_dir_fs: empty path" >&2; return 1; }

    case "$host_dir" in
        /mnt/*|/media/*|/run/media/*)
            cat >&2 <<EOF
FATAL: $host_dir looks like a removable / cross-OS mount.
       WSL mounts Windows drives under /mnt/* (9p/drvfs); Linux auto-mounts
       under /media/* or /run/media/* (often cifs/9p). SQLite WAL will fail
       with I/O errors on these filesystems.
       Use an ext4 path inside WSL, e.g. ~/bishon-data or /var/lib/bishon.
EOF
            return 1 ;;
    esac

    local fs_type
    fs_type="$(df -T "$host_dir" 2>/dev/null | awk 'NR==2 {print $2}')"
    case "$fs_type" in
        9p|drvfs|tmpfs|overlay|smbfs|cifs)
            echo "FATAL: $host_dir filesystem is '$fs_type' — not safe for SQLite WAL. Use ext4." >&2
            return 1 ;;
        "")
            echo "FATAL: could not determine filesystem of $host_dir" >&2
            return 1 ;;
    esac
    return 0
}
