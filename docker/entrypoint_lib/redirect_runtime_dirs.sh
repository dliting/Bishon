# This file is sourced by entrypoint.sh (inherits -euo pipefail).
set -euo pipefail

# Redirect source-relative BISHON_DB/ and logs/ to host-dir top level.
# Why: model_config.py computes paths as root_path/BISHON_DB and root_path/logs.
# Without redirect, writes land inside source dir → wiped on upgrade, and on
# WSL /mnt/* they hit NTFS via 9p, breaking SQLite WAL.
_redirect_one() {
    local name="$1"                      # BISHON_DB or logs
    local target="$DATA_ROOT/$name"
    local link="$DATA_ROOT/bishon/$name"
    mkdir -p "$target"
    if [ -L "$link" ]; then
        return 0
    fi
    if [ ! -e "$link" ]; then
        ln -s "$target" "$link"
        log "linked $link -> $target"
        return 0
    fi
    if rmdir "$link" 2>/dev/null; then
        ln -s "$target" "$link"
        log "linked $link -> $target (replaced empty dir)"
        return 0
    fi
    die "$link exists and is non-empty. Refusing to overwrite. Migrate its contents to $target and remove $link before restart."
}

redirect_runtime_dirs() {
    _redirect_one BISHON_DB
    _redirect_one logs
}
