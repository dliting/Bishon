#!/usr/bin/env bash
# Bishon V2 - Stop the knowledge base service

set -euo pipefail

echo "[INFO] Stopping Bishon V2..."

# Find PID listening on port 8777
PID=""
if command -v lsof &>/dev/null; then
    PID=$(lsof -ti :8777 2>/dev/null || true)
elif command -v ss &>/dev/null; then
    PID=$(ss -tlnp 'sport = :8777' 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)
elif command -v fuser &>/dev/null; then
    PID=$(fuser 8777/tcp 2>/dev/null || true)
fi
if [ -n "$PID" ]; then
    echo "[INFO] Killing process PID $PID on port 8777..."
    kill -9 $PID 2>/dev/null || true
    echo "[SUCCESS] Bishon V2 stopped."
else
    echo "[INFO] No process found on port 8777."
fi
