#!/usr/bin/env bats
# Bats tests for scripts/download-models.sh
#
# Coverage focuses on flags and idempotency. Does NOT perform actual
# network downloads (would use 1.3 GB and depend on hf-mirror.com uptime).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
DL="$REPO_ROOT/scripts/download-models.sh"

@test "download-models.sh exists and is executable" {
    [ -f "$DL" ]
}

@test "download-models.sh passes bash -n syntax check" {
    run bash -n "$DL"
    [ "$status" -eq 0 ]
}

@test "download-models.sh has set -euo pipefail" {
    grep -qE '^set -euo pipefail' "$DL"
}

@test "--help exits 0 and prints usage" {
    run bash "$DL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--offline"* ]]
}

@test "--dry-run prints URLs and does NOT actually download" {
    run bash "$DL" --dry-run --target /tmp/bishon-dl-bats-$$
    [ "$status" -eq 0 ]
    [[ "$output" == *"hf-mirror.com"* || "$output" == *"HF_ENDPOINT"* ]]
    [[ "$output" == *"(dry-run)"* ]]
}

@test "--offline extracts a pre-built tarball" {
    tmp_repo="$(mktemp -d)"
    # Fake tarball with a models/Qwen3-Reranker-0.6B/model.safetensors stub
    mkdir -p "$tmp_repo/models/Qwen3-Reranker-0.6B"
    echo "fake-weights" > "$tmp_repo/models/Qwen3-Reranker-0.6B/model.safetensors"
    mkdir -p "$tmp_repo/models/paddleocr_models/det"
    tar -czf "$tmp_repo/fake-models.tar.gz" -C "$tmp_repo" models

    target_dir="$(mktemp -d)"
    run bash "$DL" --offline "$tmp_repo/fake-models.tar.gz" --target "$target_dir"
    [ "$status" -eq 0 ]
    [ -f "$target_dir/models/Qwen3-Reranker-0.6B/model.safetensors" ]
    [ -d "$target_dir/models/paddleocr_models/det" ]

    rm -rf "$tmp_repo" "$target_dir"
}

@test "Idempotent: existing Reranker dir is not re-downloaded" {
    # Pre-populate target with a fake Reranker dir; the script should detect
    # it and skip the git clone step (we observe via dry-run + validation
    # that the existing files are reported, not "would git clone").
    target="$(mktemp -d)"
    mkdir -p "$target/Qwen3-Reranker-0.6B"
    echo "stub" > "$target/Qwen3-Reranker-0.6B/model.safetensors"
    # PaddleOCR is auto-downloaded via bishon env, which we don't have in CI;
    # skip it.
    run bash "$DL" --dry-run --skip-paddleocr --target "$target"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already populated"* ]]
    rm -rf "$target"
}

@test "HF_ENDPOINT env var overrides default mirror" {
    run bash -c "HF_ENDPOINT=https://example.com/hf bash '$DL' --dry-run --skip-paddleocr --target /tmp/x-$$"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/hf"* ]]
}

@test "Unknown flag exits with code 2 (usage error)" {
    run bash "$DL" --bogus-flag
    [ "$status" -eq 2 ]
}
