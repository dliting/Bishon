# This file is sourced by entrypoint.sh (which sets -euo pipefail).
set -euo pipefail

# Bind-mounted python-env symlinked into miniconda3 standard path.
# Why: env-internal absolute paths like
#   /opt/miniconda3/envs/bishon/lib/python3.11/site-packages/...
# were baked at env-creation time on WSL; the symlink makes them resolve
# correctly inside the container.
bind_python_env() {
    local env_link=/opt/miniconda3/envs/bishon
    local target="$DATA_ROOT/python-env"
    mkdir -p /opt/miniconda3/envs
    if [ ! -e "$env_link" ]; then
        ln -s "$target" "$env_link"
        log "linked $env_link -> $target"
    elif [ ! -L "$env_link" ]; then
        die "$env_link exists but is not a symlink. Container state corrupted."
    fi
}
