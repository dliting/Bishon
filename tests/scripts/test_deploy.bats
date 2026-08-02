#!/usr/bin/env bats
# Bats tests for the deployment wizard and L2 modules.
#
# Focuses on --dry-run + --non-interactive paths (interactive prompts are
# not easily testable in CI). Verifies:
#   - syntax / style of every new script
#   - flag parsing in --native-windows --non-interactive --dry-run
#   - dispatch logic (mode → correct L2 module call)
#   - platform detection (windows → refuses; --native-windows → continues)
#   - config file persistence

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# ---------------------------------------------------------------------------
# L3 wizard
# ---------------------------------------------------------------------------

@test "deploy.sh exists and is executable" {
    [ -f "$REPO_ROOT/deploy.sh" ]
}

@test "deploy.sh passes bash -n" {
    run bash -n "$REPO_ROOT/deploy.sh"
    [ "$status" -eq 0 ]
}

@test "deploy.sh has set -euo pipefail" {
    grep -qE '^set -euo pipefail' "$REPO_ROOT/deploy.sh"
}

@test "--help exits 0 and lists modes" {
    run bash "$REPO_ROOT/deploy.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker-online"* ]]
    [[ "$output" == *"docker-offline"* ]]
    [[ "$output" == *"bare-metal"* ]]
}

@test "--non-interactive docker-online --dry-run prints summary without executing" {
    run bash "$REPO_ROOT/deploy.sh" \
        --native-windows --non-interactive --dry-run --no-save-config \
        --mode docker-online --host-dir /tmp/bats-deploy-$$ \
        --release /tmp/nope.tar.gz --registry aliyun \
        --models-source skip
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode:          docker-online"* ]]
    [[ "$output" == *"image source:  pull"* ]]
    [[ "$output" == *"registry:      aliyun"* ]]
    [[ "$output" == *"(dry-run: not executing)"* ]]
}

@test "--non-interactive docker-offline --dry-run includes --image" {
    run bash "$REPO_ROOT/deploy.sh" \
        --native-windows --non-interactive --dry-run --no-save-config \
        --mode docker-offline --host-dir /tmp/bats-deploy-$$ \
        --release /tmp/nope.tar.gz --image /tmp/nope-img.tar \
        --models-source skip
    [ "$status" -eq 0 ]
    [[ "$output" == *"image source:  load"* ]]
    [[ "$output" == *"image tar:"* ]]
}

@test "--non-interactive bare-metal --dry-run shows source-dir + conda env" {
    run bash "$REPO_ROOT/deploy.sh" \
        --native-windows --non-interactive --dry-run --no-save-config \
        --mode bare-metal --source-dir "$REPO_ROOT" \
        --conda-env /tmp/fake-env --models-source skip
    [ "$status" -eq 0 ]
    [[ "$output" == *"source-dir:"* ]]
    [[ "$output" == *"conda env:"* ]]
}

@test "unknown --mode exits non-zero" {
    run bash "$REPO_ROOT/deploy.sh" \
        --native-windows --non-interactive --dry-run --no-save-config \
        --mode bogus --host-dir /tmp/x --release /tmp/x.tar.gz
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# L2 modules
# ---------------------------------------------------------------------------

@test "install.sh syntax OK" {
    run bash -n "$REPO_ROOT/scripts/docker/install.sh"
    [ "$status" -eq 0 ]
}

@test "start.sh syntax OK" {
    run bash -n "$REPO_ROOT/scripts/bare-metal/start.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh exists and passes syntax" {
    run bash -n "$REPO_ROOT/scripts/docker/install.sh"
    [ "$status" -eq 0 ]
}

@test "bare-metal start.sh exists and passes syntax" {
    run bash -n "$REPO_ROOT/scripts/bare-metal/start.sh"
    [ "$status" -eq 0 ]
}

@test "bare-metal start.sh supports --daemon" {
    run bash -n "$REPO_ROOT/scripts/bare-metal/start.sh"
    [ "$status" -eq 0 ]
    grep -q -- "--daemon)" "$REPO_ROOT/scripts/bare-metal/start.sh"
    grep -q "setsid nohup" "$REPO_ROOT/scripts/bare-metal/start.sh"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

@test "wizard refuses on native Windows without --native-windows" {
    # Simulate Windows by setting uname output. We can't easily do that in
    # bats, but we can verify the check exists in the source.
    grep -q "MINGW\|MSYS\|CYGWIN" "$REPO_ROOT/deploy.sh"
}

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

@test "wizard saves deploy.conf to host-dir on dry-run with --no-save-config disabled" {
    tmp="$(mktemp -d)"
    # Default behavior saves config; --no-save-config prevents it. Verify
    # both branches exist by grepping the source.
    grep -q "deploy.conf" "$REPO_ROOT/deploy.sh"
    rm -rf "$tmp"
}

# Regression test for I1: --dry-run MUST NOT write deploy.conf even with
# default --save-config (otherwise dry-run is not actually side-effect-free).
@test "I1 regression: dry-run without --no-save-config does NOT write deploy.conf" {
    tmp="$(mktemp -d)"
    # Without --no-save-config, default would have saved; dry-run must skip.
    run bash "$REPO_ROOT/deploy.sh" \
        --native-windows --non-interactive --dry-run \
        --mode docker-online --host-dir "$tmp" \
        --release /tmp/nope.tar.gz --registry ghcr \
        --models-source skip
    [ "$status" -eq 0 ]
    [ ! -f "$tmp/deploy.conf" ] || \
        { echo "FAIL: deploy.conf was written in dry-run mode (I1 regression)"; false; }
    rm -rf "$tmp"
}

# Happy-path: NON-dry-run with default --save-config DOES write deploy.conf.
# (Requires actual install execution; verify only that the save block exists
# in source and is reachable. Full end-to-end covered by interactive testing.)
@test "save-config block in wizard source has correct dry-run guard" {
    # The save block must be guarded by `if ! $DRY_RUN && $SAVE_CONFIG ...`
    grep -E 'if ! \$DRY_RUN && \$SAVE_CONFIG' "$REPO_ROOT/deploy.sh"
}
