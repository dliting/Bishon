# This file is sourced by entrypoint.sh (inherits -euo pipefail).
set -euo pipefail

# Bind-mount Node toolchain (mirrors python-env pattern).
# No-op if $DATA_ROOT/node-env/ is absent (frontend hot-rebuild disabled).
# Sets global NODE_BOUND=true on success; false on no-op or .skip-node sentinel.
bind_node_env() {
    NODE_BOUND=false
    local node_env="$DATA_ROOT/node-env"
    [ -d "$node_env" ] || return 0
    if [ -f "$node_env/.skip-node" ]; then
        log "node-env/.skip-node present — skipping"
        return 0
    fi

    local node_bin_dir
    node_bin_dir=$(ls -d "$node_env"/node-v*-linux-x64 "$node_env"/node-v*-linux-arm64 2>/dev/null | head -1)
    [ -n "$node_bin_dir" ] || die "$node_env/ present but no node-v*-linux-{x64,arm64}/ subdir found."

    [ -x "$node_bin_dir/bin/node" ] && [ -x "$node_bin_dir/bin/npm" ] \
        || die "$node_bin_dir/bin/{node,npm} missing or not executable."

    # Arch check: node binary arch must match kernel arch, else npm run build
    # would fail with "cannot execute binary file: Exec format error".
    local kernel_arch expected
    kernel_arch=$(uname -m)
    case "$kernel_arch" in
        x86_64)  expected="linux-x64" ;;
        aarch64) expected="linux-arm64" ;;
        *) die "unsupported kernel arch: $kernel_arch" ;;
    esac
    case "$node_bin_dir" in
        *-"$expected") : ;;
        *) die "Node arch mismatch: $node_bin_dir vs kernel $kernel_arch. Reinstall with NODE_ARCH=$expected." ;;
    esac

    mkdir -p /usr/local/lib/nodejs
    ln -sfn "$node_bin_dir" /usr/local/lib/nodejs/current
    export PATH="/usr/local/lib/nodejs/current/bin:$PATH"
    # Point npm cache at host-dir so it doesn't pollute the container writable layer.
    export NPM_CONFIG_CACHE="$node_env/.npm-cache"
    mkdir -p "$NPM_CONFIG_CACHE"

    # Symlink node_modules into front_end/ (preserve any user-customized real dir).
    local frontend_dir="$DATA_ROOT/bishon/front_end"
    local nm_source="$node_env/node_modules"
    if [ ! -e "$frontend_dir/node_modules" ] && [ -d "$nm_source" ]; then
        ln -s "$nm_source" "$frontend_dir/node_modules"
    elif [ -L "$frontend_dir/node_modules" ]; then
        ln -sfn "$nm_source" "$frontend_dir/node_modules"
    elif [ ! -d "$nm_source" ]; then
        log "WARN: $nm_source missing — npm ci will be needed before build can succeed"
    fi

    log "Node $(node --version) bound at $node_bin_dir, npm $(npm --version)"
    NODE_BOUND=true
}
