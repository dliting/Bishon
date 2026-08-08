#!/usr/bin/env bash
# start-bare-metal.sh — 启动 bare-metal uvicorn（wrapper → scripts/bare-metal/start.sh）
cd "$(dirname "$0")"
exec bash scripts/bare-metal/start.sh "$@"
