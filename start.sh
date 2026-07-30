#!/usr/bin/env bash
# start.sh — bare-metal entry point (wrapper → scripts/start.sh)
cd "$(dirname "$0")"
exec bash scripts/start.sh "$@"
