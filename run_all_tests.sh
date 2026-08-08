#!/usr/bin/env bash
# run_all_tests.sh — test suite entry (wrapper → scripts/run_all_tests.sh)
cd "$(dirname "$0")"
exec bash scripts/run_all_tests.sh "$@"
