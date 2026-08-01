#!/usr/bin/env bash
# stop-bare-metal.sh — 停止 bare-metal uvicorn（wrapper → scripts/bare-metal/stop.sh）
cd "$(dirname "$0")"
exec bash scripts/bare-metal/stop.sh "$@"
