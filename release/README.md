# `release/` — what ships in the tarball

This directory holds the **explicit list of paths** that go into the offline
release tarball (`bishon-release-<version>.tar.gz`, produced by
`scripts/docker/make-release.sh`).

## Why a manifest?

The previous approach rsync'd the entire repository with an exclude list,
which made the tarball contents *implicit* — easy to accidentally ship
dev-only files (`.github/`, IDE configs, scratch files) and hard to audit
"what exactly are we shipping?".

The manifest flips this: ship paths are **opt-in**, listed in
[`MANIFEST`](./MANIFEST). Anything not in the manifest doesn't ship.

## Format

Plain text, one path per line, relative to repo root.

- Lines starting with `#` (after optional whitespace) are comments.
- Blank lines are ignored.
- Trailing comments (`path  # note`) are NOT supported — use a separate
  comment line above the path.
- Paths may be files or directories. Directories are included recursively.

## Common rsync excludes

`make-release.sh` applies the following excludes to every manifest entry,
so they don't need to be repeated here:

- `__pycache__/`, `*.pyc`, `*.pyo`
- `.pytest_cache/`, `.ruff_cache/`
- `node_modules/`
- `front_end/dist/` (npm build output — redundant with `bishon_kernel/bishon_server/dist/`)
- `.git/`

Note: `bishon_kernel/bishon_server/dist/` is **not** excluded — that's where
the runtime-mounted frontend assets live, and step 0c of `make-release.sh`
verifies `dist/bishon/index.html` exists before packaging.

## Editing the manifest

1. Append a path to [`MANIFEST`](./MANIFEST).
2. Run `bash scripts/docker/make-release.sh --version <ver>` to verify it
   packages cleanly.
3. Commit the manifest change in the same commit as the path addition (so
   the manifest never lags behind the code).

## What does NOT belong in the manifest

- `.github/` — CI workflows are dev-only.
- `.vscode/`, `.idea/` — IDE configs.
- `.pre-commit-config.yaml`, `commitlint.config.js`, root-level `package*.json`
  — repo-level dev tooling.
- `BISHON_DB/`, `logs/`, `tmp_files/`, `test-results/` — runtime state (also
  rsync-excluded).
- `release/` itself — this directory is dev-side metadata.
