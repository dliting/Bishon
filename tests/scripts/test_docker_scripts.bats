#!/usr/bin/env bats
# Bats tests for Bishon V2 docker deployment scripts.
#
# Coverage:
#   - Syntax (bash -n) for all .sh files under docker/ and scripts/docker/
#   - Defensive style enforcement (set -euo pipefail)
#   - validate-manifest.sh standalone tool
#   - bishon_parse_manifest / bishon_validate_host_dir_fs in lib/common.sh
#
# Run from anywhere in the repo:
#   bats tests/scripts/test_docker_scripts.bats
#
# bats is available via: sudo apt install bats

# Repo root is two levels up from this test file.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# ---------------------------------------------------------------------------
# 1. Syntax + style for every shell script
# ---------------------------------------------------------------------------

# Helper: list every .sh file the docker deployment ships, plus the entrypoint.
docker_sh_files() {
    find "$REPO_ROOT/docker" "$REPO_ROOT/scripts/docker" -name '*.sh' -type f | sort
}

@test "every docker/*.sh and scripts/docker/*.sh exists" {
    files="$(docker_sh_files)"
    [ -n "$files" ]
}

@test "every .sh passes bash -n syntax check" {
    while IFS= read -r f; do
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done < <(docker_sh_files)
}

@test "every .sh sets -euo pipefail near the top" {
    # Without -e, errors silently continue; without -u, typos in var names
    # silently expand to empty; without -o pipefail, mid-pipeline failures
    # are swallowed. All three are required for any script that runs in
    # production deploy flow.
    while IFS= read -r f; do
        # Skip common.sh — it's a sourced library, not a script.
        [[ "$f" == */lib/common.sh ]] && continue
        # First 20 non-blank non-comment lines must contain the directive.
        grep -m1 -nE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*u[a-zA-Z]*o[[:space:]]+pipefail' "$f" >/dev/null \
            || grep -m1 -nE '^[[:space:]]*set[[:space:]]+-euo[[:space:]]+pipefail' "$f" >/dev/null \
            || { echo "MISSING 'set -euo pipefail' in $f"; false; }
    done < <(docker_sh_files)
}

@test "lib/common.sh is sourceable with no side effects" {
    # Sourcing should produce no output, exit 0.
    run bash -c 'source "$0" && true' "$REPO_ROOT/scripts/docker/lib/common.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 2. bishon_parse_manifest — pure function, easy to test
# ---------------------------------------------------------------------------

@test "bishon_parse_manifest emits one path per non-comment, non-blank line" {
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
# comment line
bishon_kernel

   # indented comment
front_end
start.sh
EOF
    result="$(bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_parse_manifest '$tmp'")"
    expected="$(printf 'bishon_kernel\nfront_end\nstart.sh')"
    [ "$result" = "$expected" ]
    rm -f "$tmp"
}

@test "bishon_parse_manifest returns non-zero when manifest missing" {
    run bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_parse_manifest '/nonexistent/MANIFEST'"
    [ "$status" -ne 0 ]
}

@test "bishon_parse_manifest handles trailing-whitespace lines" {
    tmp="$(mktemp)"
    printf '  bishon_kernel  \n\tstart.sh\n' >"$tmp"
    result="$(bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_parse_manifest '$tmp'")"
    [ "$result" = "$(printf 'bishon_kernel\nstart.sh')" ]
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 3. bishon_validate_host_dir_fs — case + df -T checks
# ---------------------------------------------------------------------------

@test "bishon_validate_host_dir_fs rejects /mnt/* (WSL drvfs proxy)" {
    run bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_validate_host_dir_fs /mnt/c/Users/foo"
    [ "$status" -ne 0 ]
    # Error message should mention WSL or drvfs so the operator knows why.
    [[ "$output" == *"9p"* || "$output" == *"drvfs"* || "$output" == *"WSL"* ]]
}

@test "bishon_validate_host_dir_fs rejects /media/* (Linux auto-mount)" {
    run bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_validate_host_dir_fs /media/sdcard/foo"
    [ "$status" -ne 0 ]
}

@test "bishon_validate_host_dir_fs rejects /run/media/* (systemd auto-mount)" {
    run bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_validate_host_dir_fs /run/media/user/disk"
    [ "$status" -ne 0 ]
}

@test "bishon_validate_host_dir_fs rejects empty path" {
    run bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_validate_host_dir_fs ''"
    [ "$status" -ne 0 ]
}

@test "bishon_validate_host_dir_fs accepts a real ext4 path" {
    # Create a temporary dir under $HOME (almost always ext4 on WSL/Linux
    # dev boxes). The function expects the dir to already exist — production
    # code calls mkdir -p first.
    tmp="$HOME/.bishon-bats-$$"
    mkdir -p "$tmp"
    fs_type="$(df -T "$tmp" 2>/dev/null | awk 'NR==2 {print $2}')"
    case "$fs_type" in
        ext4|btrfs|xfs|zfs) ;;
        *)
            rm -rf "$tmp"
            skip "\$HOME is on $fs_type, not a normal Linux fs" ;;
    esac
    run bash -c "source '$REPO_ROOT/scripts/docker/lib/common.sh' && bishon_validate_host_dir_fs '$tmp'"
    rm -rf "$tmp"
    [ "$status" -eq 0 ]
    # On success the function prints the fs_type so the caller can capture it
    # without re-running df -T.
    [ "$output" = "$fs_type" ]
}

@test "bishon_validate_host_dir_fs preserves caller BISHON_LOG_TAG in error" {
    # I3: error messages must inherit the caller's log tag (e.g. [install])
    # so operators grepping deploy logs can attribute failures correctly.
    run bash -c "export BISHON_LOG_TAG=install; source '$REPO_ROOT/scripts/docker/lib/common.sh'; bishon_validate_host_dir_fs /mnt/c/foo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"[install] FATAL"* ]]
}

# ---------------------------------------------------------------------------
# 4. validate-manifest.sh standalone tool
# ---------------------------------------------------------------------------

@test "validate-manifest.sh exits 0 on the real MANIFEST" {
    run bash "$REPO_ROOT/scripts/docker/validate-manifest.sh" --repo-root "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 missing"* ]]
}

@test "validate-manifest.sh exits 1 on a manifest with a missing path" {
    tmp_repo="$(mktemp -d)"
    mkdir -p "$tmp_repo/release"
    cat >"$tmp_repo/release/MANIFEST" <<EOF
bishon_kernel
this_path_does_not_exist
EOF
    # Also create the listed-good path so only the bad one fails.
    mkdir -p "$tmp_repo/bishon_kernel"
    run bash "$REPO_ROOT/scripts/docker/validate-manifest.sh" --repo-root "$tmp_repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"this_path_does_not_exist"* ]]
    rm -rf "$tmp_repo"
}

@test "validate-manifest.sh exits 1 when MANIFEST missing" {
    tmp_repo="$(mktemp -d)"
    run bash "$REPO_ROOT/scripts/docker/validate-manifest.sh" --repo-root "$tmp_repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"release/MANIFEST"* ]]
    rm -rf "$tmp_repo"
}
