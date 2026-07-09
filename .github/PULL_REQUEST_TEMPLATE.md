## Summary

<!-- One-paragraph summary of what this PR changes and why. -->

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Refactor (no functional change)
- [ ] Test addition / fix

## Checklist

- [ ] Code follows the [CONTRIBUTING.md](../CONTRIBUTING.md) guidelines (SOLID, no magic numbers, English identifiers, etc.).
- [ ] Added or updated tests for the change; unit-test coverage stays above 90%.
- [ ] Ran `poe test-backend` (or `pytest tests/backend/unit/`) locally — all tests pass.
- [ ] Ran `poe test-frontend` (or `cd front_end && npx vitest run`) locally — all tests pass.
- [ ] For frontend changes: rebuilt `bishon_kernel/bishon_server/dist/` and verified in a browser.
- [ ] Updated `docs/` if the change affects user-facing behavior or architecture.
- [ ] Commit message follows Conventional Commits (e.g. `feat:`, `fix:`, `chore:`, `refactor:`).

## Test plan

<!-- How did you verify this change end-to-end? Attach commands, outputs, or screenshots. -->

## Related issues

<!-- "Closes #123", "Refs #456", or "N/A". -->
