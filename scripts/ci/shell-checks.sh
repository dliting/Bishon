#!/usr/bin/env bash
# scripts/ci/shell-checks.sh
#
# Single source of truth for shell-side CI checks. CI platform YAMLs
# (GitHub Actions, GitLab CI, Gitea Actions, Jenkins Pipeline) should
# only call this script — no shell logic belongs in the YAML.
#
# Why: per docs/ci_design.md (portability memo), CI platform syntax
# (`uses:`, `runs-on:`, `image:`, `tags:`) is platform-specific and
# costly to migrate. The shell logic itself is 100% portable. Centralizing
# it here means migrating from GitHub Actions to GitLab CI / Gitea / etc.
# is a 1-line change in the YAML.
#
# Usage:
#   bash scripts/ci/shell-checks.sh           # full run (CI mode)
#   bash scripts/ci/shell-checks.sh --local   # dev mode: skip bats if missing
#
# Prerequisites:
#   - bash 4+, awk, find, sed  (POSIX-ish)
#   - bats  (CI mode requires it; --local mode skips if unavailable)
#     Install: apt install bats | brew install bats-core | pre-bake into image
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed
#   2  usage error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

ALLOW_MISSING_BATS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local) ALLOW_MISSING_BATS=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

fail=0

# --- 1. bash -n syntax check on every .sh under docker/ and scripts/docker/ --
echo "=== 1/3 bash -n syntax check ==="
sh_count=0
while IFS= read -r f; do
    sh_count=$((sh_count + 1))
    if ! bash -n "$f"; then
        echo "FAIL: $f"
        fail=1
    fi
done < <(find docker scripts/docker -name '*.sh' -type f 2>/dev/null | sort)
echo "checked $sh_count files"

# --- 2. release/MANIFEST validation ------------------------------------------
echo
echo "=== 2/3 release/MANIFEST validation ==="
if ! bash scripts/docker/validate-manifest.sh --repo-root .; then
    fail=1
fi

# --- 3. bats tests -----------------------------------------------------------
echo
echo "=== 3/3 bats tests ==="
if command -v bats >/dev/null 2>&1; then
    if ! bats tests/scripts/*.bats; then
        fail=1
    fi
elif $ALLOW_MISSING_BATS; then
    echo "WARN: bats not on PATH; skipping bats tests (--local mode)."
    echo "      Install: apt install bats | brew install bats-core |"
    echo "      pre-bake into CI image."
else
    cat >&2 <<EOF
FATAL: bats not on PATH. CI mode requires it.
   Install:
     apt install bats          # Debian/Ubuntu
     brew install bats-core    # macOS
     pre-bake into CI image    # internal restricted networks
   Or run with --local to skip bats tests.
EOF
    fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT: all shell checks passed."
else
    echo "RESULT: shell checks FAILED."
fi
exit $fail
