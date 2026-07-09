# Contributing to Bishon V2

Thanks for considering a contribution! This document explains the conventions
that keep the codebase healthy and approachable for new contributors.

## Quick start

```bash
# 1. Create the conda environment.
conda create -n bishon python=3.11 -y
conda activate bishon

# 2. Install Python dependencies.
pip install -r requirements.txt -r requirements-dev.txt

# 3. Configure the runtime (.env is gitignored; copy from .env.example).
cp .env.example .env
# Edit .env: set OPENAI_API_BASE, OPENAI_API_KEY, EMBEDDING_API_BASE, etc.

# 4. Frontend: install + build into bishon_kernel/bishon_server/dist/.
cd front_end && npm ci && npm run build && cd ..

# 5. Run.
./start.sh        # Linux / WSL
start.bat         # Windows
```

## Project layout

```
bishon_kernel/          Backend (FastAPI + FAISS + SQLite + PaddleOCR + Rerank)
  configs/              Configuration center (single .env entry point)
  connector/            Data connectors (database / embedding / rerank / llm)
  core/                 Core QA + file-processing logic
  bishon_server/        FastAPI app, handlers, served frontend dist
  utils/                Shared utilities
front_end/              Vue 3 + Vite frontend source
tests/                  Backend unit / integration + frontend unit / e2e
docs/                   User-facing docs (API.md, design/, ui-test-steps.md)
scripts/                Helper scripts
```

## Engineering principles

### SOLID
Every class and module should have a single responsibility. Depend on
abstractions, not concretions. New functionality should be additive rather
than invasive.

### Defensive programming — but not over-defensive
This is an internal-use tool. Validate at system boundaries (HTTP requests,
file uploads, external APIs). Do not add defensive checks inside trusted
internal code paths. Don't silently swallow runtime errors — log them or
raise.

### Logging
The receive, process, and send stages of any data flow must log. Use the
existing loggers (`debug_logger`, `qa_logger` from `bishon_kernel.utils.custom_log`).
Do not introduce a new logger without coordinating with maintainers.

### Naming
- Use **English** for all identifiers, field names, and code comments.
- Database table and column names: English (no pinyin abbreviations).
- Project naming convention:
  - Package names and paths: `bishon` (lowercase) — e.g. `bishon_kernel`.
  - Brand, titles, headings: `Bishon` (capitalized).
  - Release version: `Bishon V2`.

### Constants over magic numbers
Replace literal numbers with named constants, e.g. `DEFAULT_BATCH_SIZE_MIN = 1`
rather than embedding `1` inline.

### Code style
- Python: black/ruff-compatible (line length 100, see `pyproject.toml`).
- Align `=` in assignment blocks: same column for the right-hand side, type
  annotation colons do not need to align.
- Frontend: ESLint + Prettier (see `front_end/.eslintrc.js`, `front_end/.prettierrc.js`).

## Test-driven development

- Write the failing test first, then the implementation. Keep tests focused.
- Unit-test coverage should be **above 90%**.
- Tests must include **real tests**, not only mocks. Examples:
  - Real SQLite (via `tests/backend/conftest.py:tmp_db` fixture).
  - Real FAISS CPU index (via `tmp_faiss` fixture).
  - Real LLM and Embedding endpoints in `tests/backend/integration/test_pipeline_real.py`
    (requires Ollama running on localhost:11434).
- Frontend tests must include real browser interactions via Playwright. See
  `docs/ui-test-steps.md` for the reusable UI test-step playbook.
- After modifying code, run the affected functional tests, then the regression
  and integration tests.
- Test scripts and temporary data live under `test/temp/` and must be cleaned
  up after the test passes.
- Each test case should have a short timeout (e.g. 3 minutes max) — a hanging
  test usually means a real bug.

## The "review → verify → refine" loop

When finishing a non-trivial change (a feature, a refactor, a multi-file bug
fix), iterate through this loop until **a fresh review pass finds no new
issues** — not just until found issues have been fixed. Avoid reducing review
scope to dodge problems; widening the audit is how the codebase gets healthier.

1. **Review**: re-read the diff and adjacent code with fresh eyes.
2. **Verify**: run the relevant tests and check real runtime behavior.
3. **Refine**: fix what the review surfaced. Go back to step 1.

When diagnosing, look at the whole picture, not just the surface symptom.

## Adding or changing functionality

- Consider whether the change actually earns its keep. Avoid speculative
  features and over-engineering. "Three similar lines is better than a
  premature abstraction."
- A change must not break existing functionality. If a breaking change is
  unavoidable, document it in `CHANGELOG.md` and call it out in the PR
  description.
- Update `docs/` when the change affects user-visible behavior, API surface,
  or architecture.

## Directory conventions

- Documentation → `docs/`.
- SQL scripts → `sql/` (currently unused; SQLite schema is created by code).
- Test temp data → `test/temp/` (cleaned up after passing).

## Database

- Table and column names: English, no pinyin.
- **Schema is validated at startup**: missing required columns cause the
  application to exit, not silently run on a corrupt DB.
- Persistence failures must propagate. Don't catch + log + continue; raise so
  the caller knows.
- Independent data entities should be persisted along independent paths — don't
  couple persistence of entity A to the success of entity B.

## Pre-commit checklist

Before pushing:

- [ ] `poe lint` (or `ruff check .`) passes.
- [ ] `poe test-backend` passes (`pytest tests/backend/unit/ -v`).
- [ ] `poe test-frontend` passes (`cd front_end && npx vitest run`).
- [ ] If frontend changed: rebuilt `bishon_kernel/bishon_server/dist/`
      (`cd front_end && npm run build`) and verified in a browser.
- [ ] If you touched document ingestion, OCR, or rerank: ran
      `tests/backend/integration/test_pipeline_real.py` against a real
      Ollama endpoint.
- [ ] CHANGELOG updated if user-visible.
- [ ] Commit message follows Conventional Commits.

## Internationalization (i18n)

Frontend translations live under `front_end/src/language/`:

- `zh.ts` — Chinese
- `en.ts` — English
- `index.ts` — selector + fallback

To add a new language:

1. Copy `front_end/src/language/en.ts` to `<locale>.ts` (e.g. `ja.ts`).
2. Translate every value. Keep keys identical to the English file.
3. Register the new locale in `front_end/src/language/index.ts`.
4. Add a unit test under `front_end/test/unit/language/` to verify every key
   in your new file matches the keys in `en.ts`.

## Commit message convention

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <subject>

[optional body]
```

Types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`, `ci`.

Examples:
- `feat: add /api/health endpoint for deployment probes`
- `fix: prevent FAISS index corruption on interrupted save`
- `refactor: extract ocr_data_to_numpy into utils.ocr_utils`

## Filing pull requests

See `.github/PULL_REQUEST_TEMPLATE.md`. Open PRs against the `main` branch.

## Licensing

By contributing, you agree that your contributions are licensed under the MIT
License (see `LICENSE`).
