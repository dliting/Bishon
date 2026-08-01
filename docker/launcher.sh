#!/usr/bin/env bash
# Bishon V2 container stub launcher.
#
# Why: keep this minimal and stable. The real entrypoint logic lives at
# /opt/bishon-data/bishon/docker/entrypoint.sh (bind-mounted from host-dir)
# and can be upgraded via upgrade.sh without rebuilding this image.
#
# This file is the ONLY script baked into the image. Changing it requires
# an image rebuild; everything else can be hot-swapped via bind-mount.
set -euo pipefail

REAL=/opt/bishon-data/bishon/docker/entrypoint.sh

if [ ! -x "$REAL" ]; then
    echo "[launcher] FATAL: $REAL missing or not executable." >&2
    echo "[launcher]        Run install.sh to populate /opt/bishon-data/ first." >&2
    exit 1
fi

exec "$REAL" "$@"
