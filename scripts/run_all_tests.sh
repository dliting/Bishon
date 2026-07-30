#!/bin/bash
# Bishon V2 — run all tests.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."   # repo root (run from scripts/ via root wrapper)

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
SHELL_PASS=0
SHELL_FAIL=0
for bats_file in tests/scripts/*.bats; do
  [ -f "$bats_file" ] || continue
  if bats "$bats_file"; then
    SHELL_PASS=$((SHELL_PASS + 1))
  else
    SHELL_FAIL=$((SHELL_FAIL + 1))
  fi
done
if [ "$SHELL_FAIL" -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "All shell test files passed ($SHELL_PASS files)"
else
  FAIL=$((FAIL + 1))
  echo "Shell test failures: $SHELL_FAIL of $((SHELL_PASS + SHELL_FAIL)) files failed"
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
