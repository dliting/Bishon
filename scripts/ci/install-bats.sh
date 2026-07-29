#!/usr/bin/env bash
# scripts/ci/install-bats.sh
#
# Install bats if not already on PATH. Used by CI YAMLs to handle multiple
# platforms (GitHub Actions ubuntu-latest, GitLab CI Debian runners, macOS
# dev machines, internal CI base images).
#
# Order of attempts:
#   1. Skip if bats already on PATH.
#   2. apt-get install bats       (if apt-get is available + sudo or root)
#   3. brew install bats-core     (if Homebrew is available)
#   4. Download + install.sh      (if curl works; installs to ~/.local)
#
# Internal CI without internet: set BISHON_CI_BATS_PREINSTALLED=1 in your
# runner env. This script then expects bats to be on PATH already (you
# pre-baked it into the base image); it fails loudly if not, instead of
# silently skipping bats tests.
#
# Note: for most setups you do NOT need to call this script at all. The
# shell-checks.sh test runner auto-uses the vendored bats-core under
# third_party/bats-core/ if system bats is missing. This script is for
# cases where you want bats installed system-wide (e.g. interactive dev
# shells, CI base image build time).
#
# Usage:
#   bash scripts/ci/install-bats.sh
#   BISHON_CI_BATS_PREINSTALLED=1 bash scripts/ci/install-bats.sh

set -euo pipefail

# --- 0. Already installed? ---
if command -v bats >/dev/null 2>&1; then
    echo "[install-bats] bats already on PATH: $(command -v bats) ($(bats --version))"
    exit 0
fi

# --- 0b. Pre-installed mode (internal CI) ---
if [ "${BISHON_CI_BATS_PREINSTALLED:-0}" = "1" ]; then
    cat >&2 <<EOF
[install-bats] FATAL: BISHON_CI_BATS_PREINSTALLED=1 but bats not found on PATH.
       Pre-install bats in your CI base image. Options:
         Debian/Ubuntu base: apt-get install -y bats
         Alpine base:        apk add --no-cache bats
         Custom Dockerfile:  see https://bats-core.bats-core.nixlda.dev/installation.html
EOF
    exit 1
fi

# --- 1. apt-get ---
if command -v apt-get >/dev/null 2>&1; then
    if [ "$(id -u)" = "0" ]; then
        echo "[install-bats] apt-get install bats (root)"
        apt-get update && apt-get install -y bats
        exit 0
    elif command -v sudo >/dev/null 2>&1; then
        echo "[install-bats] sudo apt-get install bats"
        sudo apt-get update && sudo apt-get install -y bats
        exit 0
    fi
fi

# --- 2. brew ---
if command -v brew >/dev/null 2>&1; then
    echo "[install-bats] brew install bats-core"
    brew install bats-core
    exit 0
fi

# --- 3. Source install (last resort; needs curl + tar + sh) ---
if command -v curl >/dev/null 2>&1; then
    # Read version from the vendored copy if present (keeps single source of
    # truth). Fall back to a sensible default.
    VENDORED_VERSION_FILE="$(cd "$(dirname "$0")/../.." && pwd)/third_party/bats-core/VERSION"
    if [ -f "$VENDORED_VERSION_FILE" ]; then
        BATS_VERSION="$(cat "$VENDORED_VERSION_FILE" | xargs)"
    else
        BATS_VERSION="1.2.1"
    fi
    echo "[install-bats] source install v${BATS_VERSION} to ~/.local (last-resort)"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    URL="https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz"
    if curl -fsSL "$URL" -o "$TMP/bats.tar.gz"; then
        tar -xzf "$TMP/bats.tar.gz" -C "$TMP"
        "$TMP/bats-core-${BATS_VERSION}/install.sh" "$HOME/.local"
        echo "[install-bats] Installed. Ensure PATH includes \$HOME/.local/bin:"
        echo "                 export PATH=\"$HOME/.local/bin:\$PATH\""
        exit 0
    fi
    echo "[install-bats] source install failed (curl error)." >&2
fi

# --- 4. Nothing worked ---
cat >&2 <<EOF
[install-bats] FATAL: could not install bats automatically.
       For shell-checks.sh, you don't need system bats — the vendored
       third_party/bats-core/bin/bats is used as fallback automatically.
       For other uses, pre-install bats or set BISHON_CI_BATS_PREINSTALLED=1.
EOF
exit 1
