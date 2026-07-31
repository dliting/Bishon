#!/usr/bin/env bats
# Tests for Bishon V2 start scripts (Docker + bare-metal wrappers)

ROOT="$BATS_TEST_DIRNAME/../.."

@test "start-docker.sh exists and passes syntax" {
    [ -f "$ROOT/start-docker.sh" ]
    run bash -n "$ROOT/start-docker.sh"
    [ "$status" -eq 0 ]
}

@test "stop-docker.sh exists and passes syntax" {
    [ -f "$ROOT/stop-docker.sh" ]
    run bash -n "$ROOT/stop-docker.sh"
    [ "$status" -eq 0 ]
}

@test "start-bare-metal.sh exists and passes syntax" {
    [ -f "$ROOT/start-bare-metal.sh" ]
    run bash -n "$ROOT/start-bare-metal.sh"
    [ "$status" -eq 0 ]
}

@test "stop-bare-metal.sh exists and passes syntax" {
    [ -f "$ROOT/stop-bare-metal.sh" ]
    run bash -n "$ROOT/stop-bare-metal.sh"
    [ "$status" -eq 0 ]
}

@test "necessary directories exist or can be created" {
    cd "$ROOT"
    mkdir -p logs/debug_logs logs/qa_logs BISHON_DB/faiss BISHON_DB/content
    [ -d "logs/debug_logs" ]
    [ -d "logs/qa_logs" ]
    [ -d "BISHON_DB/faiss" ]
    [ -d "BISHON_DB/content" ]
}

@test "API docs endpoint returns Bishon V2 info" {
    if ! curl -s --connect-timeout 2 http://localhost:8777/api/docs > /dev/null 2>&1; then
        skip "Service not running on port 8777"
    fi
    result=$(curl -s http://localhost:8777/api/docs)
    echo "$result" | grep -q "Bishon V2"
}
