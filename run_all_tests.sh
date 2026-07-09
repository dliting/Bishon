#!/bin/bash
# Bishon V2 — run all tests.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0

echo "=== 1/5 Backend Unit Tests ==="
if python -m pytest tests/backend/unit/ -v --tb=short; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== 2/5 Backend Integration Tests ==="
if python -m pytest tests/backend/integration/ -v --tb=short; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== 3/5 Frontend Unit Tests ==="
cd front_end
if npx vitest run; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi
cd ..

echo ""
echo "=== 4/5 Shell Script Tests ==="
if bats tests/scripts/test_start_sh.sh; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== 5/5 E2E Tests (requires running backend) ==="
if curl -s --connect-timeout 2 http://localhost:8777/api/docs > /dev/null 2>&1; then
  cd front_end
  npx playwright test --config=../tests/frontend/e2e/playwright.config.ts
  cd ..
  PASS=$((PASS + 1))
else
  echo "(Skipped: backend not running on port 8777)"
fi

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="
