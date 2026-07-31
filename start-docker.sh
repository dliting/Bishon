#!/usr/bin/env bash
# start-docker.sh — 启动 Docker 容器（wrapper → scripts/docker/start.sh）
cd "$(dirname "$0")"
exec bash scripts/docker/start.sh "$@"
