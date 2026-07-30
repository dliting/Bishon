#!/usr/bin/env bash
# stop.sh — bare-metal stop (wrapper → scripts/stop.sh)
cd "$(dirname "$0")"
exec bash scripts/stop.sh "$@"
