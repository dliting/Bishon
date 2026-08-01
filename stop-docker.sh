#!/usr/bin/env bash
# stop-docker.sh — 停止 Docker 容器（wrapper → scripts/docker/stop.sh）
cd "$(dirname "$0")"
exec bash scripts/docker/stop.sh "$@"
