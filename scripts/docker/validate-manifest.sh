#!/usr/bin/env bash
# validate-manifest.sh — check that every path in release/MANIFEST exists.
#
# Standalone tool used by:
#   - humans auditing what would ship
#   - bats tests (test_docker_scripts.bats)
#   - CI pre-commit hooks (optional)
#
# Exit codes:
#   0  all paths exist
#   1  one or more paths missing (or manifest missing)
#   2  usage error
#
# Usage:
#   bash scripts/docker/validate-manifest.sh [--repo-root <path>]
#
# Default repo root is two levels up from this script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--repo-root <path>]
Checks release/MANIFEST: every listed path must exist under <repo-root>.
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

source "$(dirname "$0")/lib/common.sh"

MANIFEST="$REPO_ROOT/release/MANIFEST"
[ -f "$MANIFEST" ] || {
    echo "FATAL: $MANIFEST not found." >&2
    exit 1
}

missing=0
total=0
while IFS= read -r path; do
    total=$((total + 1))
    if [ ! -e "$REPO_ROOT/$path" ]; then
        echo "MISSING: $path"
        missing=$((missing + 1))
    fi
done < <(bishon_parse_manifest "$MANIFEST")

echo "Manifest checked: $total paths, $missing missing"
[ "$missing" -eq 0 ]
