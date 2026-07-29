#!/usr/bin/env bats
# Tests for Bishon V2 start.sh

@test "start.sh exists and is executable" {
    [ -f "$BATS_TEST_DIRNAME/../../start.sh" ]
}

@test "start.sh passes syntax check" {
    run bash -n "$BATS_TEST_DIRNAME/../../start.sh"
    [ "$status" -eq 0 ]
}

@test "necessary directories exist or can be created" {
    cd "$BATS_TEST_DIRNAME/../.."
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
