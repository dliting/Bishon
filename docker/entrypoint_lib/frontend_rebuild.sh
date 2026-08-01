# This file is sourced by entrypoint.sh (inherits -euo pipefail); also
# usable by bats for unit testing (bats overrides PATH variables).
set -euo pipefail

# Frontend conditional rebuild — runs `npm run build` when source is newer
# than dist. No-op when NODE_BOUND=false (node-env/ missing).
#
# Paths are computed from $DATA_ROOT (set by entrypoint.sh). bats tests can
# override FRONTEND_SRC_DIR / FRONTEND_ROOT / DIST_INDEX directly.

: "${FRONTEND_SRC_DIR:=$DATA_ROOT/bishon/front_end/src}"
: "${FRONTEND_ROOT:=$DATA_ROOT/bishon/front_end}"
: "${DIST_INDEX:=$DATA_ROOT/bishon/bishon_kernel/bishon_server/dist/bishon/index.html}"

# Returns 0 (true) if rebuild needed, 1 (false) otherwise.
frontend_needs_rebuild() {
    [ -f "$DIST_INDEX" ] || return 0   # no dist → must build

    local dist_mtime newest=0 m f src_seen=false
    dist_mtime=$(stat -c %Y "$DIST_INDEX" 2>/dev/null || echo 0)

    while IFS= read -r f; do
        src_seen=true
        m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        [ "$m" -gt "$newest" ] && newest=$m
    done < <(find "$FRONTEND_SRC_DIR" -type f \
        \( -name '*.vue' -o -name '*.ts' -o -name '*.scss' -o -name '*.css' -o -name '*.json' \) 2>/dev/null)

    for cfg in "$FRONTEND_ROOT/.env.production" "$FRONTEND_ROOT/package.json" \
               "$FRONTEND_ROOT/package-lock.json" "$FRONTEND_ROOT/vite.config.ts" \
               "$FRONTEND_ROOT/index.html"; do
        [ -e "$cfg" ] || continue
        m=$(stat -c %Y "$cfg" 2>/dev/null || echo 0)
        [ "$m" -gt "$newest" ] && newest=$m
    done

    if [ "$src_seen" = "false" ]; then
        log "WARN: no source files matched under $FRONTEND_SRC_DIR (frontend_needs_rebuild assumes dist is current)"
        return 1
    fi

    [ "$newest" -gt "$dist_mtime" ]
}

maybe_rebuild_frontend() {
    [ "${NODE_BOUND:-false}" = "true" ] || return 0
    cd "$FRONTEND_ROOT"
    if frontend_needs_rebuild; then
        log "frontend source newer than dist → running npm run build"
        set +e
        timeout 300 npm run build 2>&1 | sed 's/^/[npm] /'
        local rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 124 ]; then
                die "npm run build timed out after 300s."
            else
                die "npm run build failed (exit $rc). See [npm] lines above."
            fi
        fi
        log "frontend dist rebuilt"
    else
        log "frontend dist up-to-date, skipping rebuild"
    fi
}
