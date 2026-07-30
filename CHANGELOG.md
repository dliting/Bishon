# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`scripts/docker/bishon-deploy.sh`** — top-level interactive deployment wizard. Covers three modes: `docker-online` (pull from ghcr.io or Aliyun), `docker-offline` (load local tar), `bare-metal` (no Docker). `--non-interactive` + flag-per-question for CI/batch deploy. `--dry-run` walks through everything without executing. Persists choices to `<host-dir>/deploy.conf` for next-run defaults. Detects native Windows and suggests WSL2.
- **`scripts/docker/bishon-deploy-docker.sh`** — L2 module: orchestrates `install.sh` + `start.sh` for Docker modes. Forwards all relevant flags.
- **`scripts/docker/bishon-deploy-bare-metal.sh`** — L2 module: `preflight --mode bare-metal` → optional `pip install -r requirements.txt` → `download-models.sh` → `start.sh`.
- **`scripts/docker/bishon-publish-image.sh`** — manual one-shot push of locally built image to ghcr.io and/or Aliyun registry. `--registry ghcr|aliyun|both` (default both), `--vpc` switches Aliyun to VPC endpoint (faster from Aliyun ECS), `--no-latest` skips `:latest` tag. Reads `$GHCR_TOKEN` / `$ALIYUN_PWD` only if not already logged in via `~/.docker/config.json`.
- **`scripts/docker/bishon-install.sh --pull` / `--registry`** — online image acquisition. Baked-in well-known registries: `ghcr` (`ghcr.io/dliting`), `aliyun` (`crpi-cpr1xsemy1pzwjoc.cn-beijing.personal.cr.aliyuncs.com/dliting`), `aliyun-vpc` (VPC endpoint). Supports custom URLs too.
- **`scripts/docker/preflight.sh --mode`** — `release` (default) | `docker-online` | `docker-offline` | `bare-metal`. Docker image check now mode-aware (bare-metal skips entirely; docker-online just checks Docker availability).
- **`scripts/download-models.sh`**: idempotent model downloader for new developers and deploy hosts. Defaults to `hf-mirror.com` (HuggingFace China mirror); PaddleOCR models auto-fetched via the `paddleocr` package. Flags: `--target`, `--dry-run`, `--offline <tar>`, `--skip-rerank`, `--skip-paddleocr`. Respects `HF_ENDPOINT`, `RERANK_REPO`, `BISHON_PY` env vars.
- **Models tarball separation**: `make-release.sh` now produces `bishon-models-<ver>.tar.gz` as a standalone artifact, separate from the main release tarball. `bishon-install.sh --models <tar>` accepts it optionally — install without models is valid (Rerank disabled, OCR warns at startup).
- **`make-release.sh --src-only`**: skips env + models + image; produces a tiny source-only tarball in ~5s for quick publish testing.
- **SHA256 checksums**: every tarball now ships with a matching `.sha256` file for deploy-side integrity verification.
- **`scripts/docker/preflight.sh`**: standalone release-readiness checker (env presence, WSL Ubuntu version, env imports, frontend dist, paddleocr models, docker image). Called by `make-release.sh`; also usable ad-hoc.
- **`bishon-cuda:latest` tag**: `bishon-build.sh` now also tags the image as `latest` for CI/automation convenience.

### Changed
- **`bishon-env/` renamed to `python-env/`** in the host-dir layout. Breaking change — existing v2.1.x deployments must re-run install. Affected files: `entrypoint.sh`, `Dockerfile.{cuda,ascend}`, `bishon-install.sh`, `bishon-publish.sh`, `make-release.sh`, `preflight.sh`, `docs/deployment.md`. (CHANGELOG keeps the historical reference under [2.1.0].)
- **`bishon-build.sh` / `make-release.sh`** now default `--version` to the contents of the `VERSION` file at repo root. Single source of truth for the project; `--version <ver>` still works as override.
- `make-release.sh` pre-flight checks refactored to delegate to `preflight.sh` (single source of truth).
- `download-models.sh --dry-run` now reflects actual filesystem state: prints "would skip" for already-populated dirs instead of unconditionally saying "would download".

### Documentation
- `docs/deployment.md` 重排：开头改为 wizard 入口 + 三模式对比表；老脚本降级为"高级用法"。
- `README.md` Quick Start: new step 5 "Download model weights" pointing to `scripts/download-models.sh`.
- `docs/dev-environment.md`: documents the script's flags and env vars; clarifies that `--target` only affects Reranker placement (PaddleOCR path is hardcoded by `model_config.py`).
- `docs/deployment.md` "前置条件": clarifies three ways to acquire models (online via script, offline via tarball, or pre-existing dir copy).

### Test
- `tests/scripts/test_bishon_deploy.bats`: 14 new cases covering wizard syntax/style, `--help`, `--non-interactive --dry-run` for all three modes, unknown-mode rejection, L2 module syntax + dry-runs, platform detection, and config persistence. Bats suite: 29 → 43.
- `tests/scripts/test_download_models.bats`: 9 cases covering syntax, defensive style, `--help`, `--dry-run`, `--offline` tarball extraction, idempotency, `HF_ENDPOINT` override, and unknown-flag exit code.

### Operational
- Git workflow: introduced `dev` branch for daily development; `main` reserved for tagged releases. CI now triggers on `main` + `dev` pushes.
- Local worktree layout documented: `I:\Bishon\V2\{main,dev}\` (Windows junctions) + `/opt/Bishon/V2/{main,dev}/` (WSL ext4 symlinks), sharing `models-shared/` to avoid duplicating 2.5 GB.

## [2.1.0] - 2026-07-29

### Added
- **Offline Docker deployment** (`bishon-cuda:<version>` image + release tarball workflow). Full operator pipeline: `bishon-build.sh` → `make-release.sh` → `bishon-install.sh` → `bishon-start.sh` → `bishon-publish.sh` (upgrade) → `bishon-uninstall.sh`. See `docs/deployment.md`.
- **Docker image `bishon-cuda:2.1.0`** (~3 GiB): CUDA 12.1 runtime + Ubuntu 22.04 + tzdata + miniconda3 base (envs injected at runtime via bind mount + entrypoint symlink).
- **`docker/Dockerfile.ascend`** placeholder for future Huawei Ascend (CANN) image variant.
- **Release manifest** (`release/MANIFEST`): explicit opt-in list of paths that ship in the release tarball. Replaces the prior "rsync everything + exclude list" pattern.
- **`scripts/docker/lib/common.sh`**: shared helpers (`bishon_log`, `bishon_die`, `bishon_warn`, `bishon_parse_manifest`, `bishon_validate_host_dir_fs`) — single source of truth for log formatting and deploy-time filesystem safety check.
- **`scripts/docker/validate-manifest.sh`**: standalone tool that audits `release/MANIFEST`; used by humans, bats tests, and CI.
- **`scripts/ci/shell-checks.sh`**: portable shell-side CI logic (bash -n, MANIFEST validation, bats tests). Decouples CI logic from CI platform syntax (GitHub Actions / GitLab CI / Gitea / Jenkins). See `docs/ci.md`.
- **`scripts/ci/install-bats.sh`**: optional system-wide bats installer (apt → brew → source from GitHub).
- **Vendored bats-core v1.2.1** under `third_party/bats-core/` (MIT). Lets CI run shell checks without internet access — important for internal CI runners without apt mirror access.
- **Bats test coverage**: `tests/scripts/test_docker_scripts.bats` (16 cases) + `tests/scripts/test_start_sh.bats` (4 cases). Covers syntax/style of every deploy script, the manifest parser, filesystem-safety check (rejects `/mnt/*`, `/media/*`, `/run/media/*` and known-bad fs types), and the standalone validate-manifest tool.
- **`docs/dev-environment.md`**: WSL ext4 + models-symlink workflow with the SQLite-WAL-needs-shm-vs-read-only-binary-weights rationale.
- **`docs/ci.md`**: CI portability design — what stays vs what gets rewritten when migrating from GitHub Actions to GitLab CI / Gitea / Jenkins.
- **`docs/deployment.md`**: 300-line operator guide covering prerequisites, image build, release packaging, install, start, upgrade, uninstall, and the Docker避坑指南 mapping (host.docker.internal, SQLite WAL on 9p, UTC tz, publish overwrite, post-deploy verification).
- **README.md "Docker deployment (optional)" section** with end-to-end command example and link to `docs/deployment.md`.
- **`CHANGELOG.md`** at v2.1.0 (this entry).
- **CI shell job** in `.github/workflows/ci.yml` running alongside backend (Python 3.11/3.12) and frontend (Node 20) jobs.

### Changed
- **Entrypoint redirects BISHON_DB/logs** from source-relative paths to `/opt/bishon-data/` top via symlinks. Fixes two latent issues: (1) publish replacing `bishon/` would wipe user data; (2) WSL `/mnt/*` source dirs trigger SQLite WAL I/O errors via 9p/NTFS.
- **`.env` injected via `docker run --env-file`** so the config file lives at `/opt/bishon-data/.env` (publish-safe sibling of source) while `model_config.py`'s `load_dotenv(root_path/.env)` keeps working as a no-op.
- **`bishon-build.sh` size output**: replaced `divf` Go template function (unavailable on older Docker) with awk.
- **`Dockerfile.cuda` miniconda download**: multi-source fallback (Tsinghua mirror first, official second) to handle China network conditions.
- **`Dockerfile.cuda` HEALTHCHECK `start-period`**: bumped 120s → 180s to match `bishon-start.sh`'s polling window.
- **`bishon-install.sh` `/mnt/*` check** widened to also reject `/media/*`, `/run/media/*` (Linux auto-mount locations).
- **`bishon-install.sh` and `bishon-publish.sh`** now use `mktemp -d -p "$HOST_DIR"` so the staging dir is on the same filesystem as the destination, guaranteeing atomic rename(2) on interrupted publish/install.
- **`bishon-start.sh` `/bishon/` non-200 fails start**: missing frontend assets now fail loudly instead of silently shipping a broken UI.
- **`bishon-start.sh` `--gpus all` fails fast** when NVIDIA Container Toolkit isn't registered with Docker (prevents 180s health-check timeout confusion).
- **`make-release.sh` MANIFEST-driven** instead of rsync-with-excludes. Ship content is auditable at a glance.
- **`make-release.sh` pre-checks**: bishon env import (torch/faiss/paddle/transformers/langchain), WSL Ubuntu version match (22.04), `bishon_kernel/bishon_server/dist/bishon/index.html` exists, `models/paddleocr_models/` has ≥4 subdirs.
- **`bishon-publish.sh` pre-flight** also checks `.image-tag` and `bishon-env/bin` exist — fail-fast with clear messages instead of letting downstream `bishon-start.sh` fail mysteriously.
- **All deploy scripts migrated** to shared `bishon_log`/`bishon_die` via `BISHON_LOG_TAG=<tag>`. Single source of truth for log formatting; uniform tag handling in error messages.
- **`run_all_tests.sh` auto-discovers** `tests/scripts/*.bats` instead of hard-coding filenames.
- **`requirements.txt` line 1 comment** updated: `无 Docker 依赖` → `主进程不依赖 Docker；离线 Docker 部署见 docs/deployment.md`.
- **`.github/workflows/ci.yml` `npm ci`** now passes `--legacy-peer-deps` to work around pinia peer-dep conflict (tracked for upgrade in v2.2).
- **`CLAUDE.md` (local-only, gitignored)** adds "工作目录与符号链接原则（WSL）" section.

### Fixed
- Various ruff lint warnings: `# noqa` annotations on FastAPI/uvicorn imports that must follow sys.path manipulation (E402); FastAPI multipart-default idiom (B008); `zip(..., strict=False)` per PEP 618 (Python 3.10+); unused-loop-variable convention `_key`; f-string instead of `%` formatting.
- `tests/scripts/test_start_sh.sh` renamed to `test_start_sh.bats` so the new `run_all_tests.sh` glob rediscovers it (was silently dropped during the test-runner refactor).

### Security
- `bishon-uninstall.sh` refuses `rm -rf` even with `--purge-data` — operator must run `rm -rf <host-dir>` manually. Prevents catastrophic data loss from a mis-typed path argument.

### Documentation
- `README.md` Roadmap updated to mark v2.1 (Docker) as current; v2.2 lists multimodal ingestion, pluggable storage, Ascend image.
- `NOTICE` now lists embedded third-party source (bats-core v1.2.1, MIT).
- `.gitattributes` extends LF enforcement to `*.bash`.

### Operational
- End-to-end validated: image builds (2.9 GiB), container cold-starts in 12s, SQLite WAL works on ext4 (journal_mode=wal, busy_timeout=5000), KB create/list/persist all pass. Smoke test against real release tarball (`make-release.sh` → `bishon-install.sh` → `bishon-start.sh`) passes.

## [2.0.0] - 2026-07-07

### Added
- Initial public release of Bishon V2.
- Local-first knowledge base QA system: FastAPI + FAISS + SQLite + PaddleOCR + in-process Rerank.
- Vue 3 + Vite + TypeScript + Ant Design Vue frontend with SSE streaming chat.
- Multi-format document ingestion: PDF, Word (docx), PPT, TXT, images (jpg/png/jpeg), CSV, Excel, EML, Markdown, web URLs.
- Document traceability: click a source document to open the original file.
- Health endpoint (`GET /api/health`) for deployment probes.
- MIT License, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY policy.

### Architecture
- Replaces the original Docker Compose stack (Milvus + etcd + MinIO + Elasticsearch + MySQL + Triton) with a single-process deployment.
- FAISS (file-persisted) instead of Milvus.
- SQLite (WAL mode) instead of MySQL.
- SQLite FTS5 (default off) instead of Elasticsearch.
- External OpenAI-compatible HTTP API for LLM and Embedding (Ollama / vLLM / OpenAI).
- In-process Qwen3-Reranker (transformers) instead of Triton rerank microservice.
- In-process PaddleOCR 3.x instead of OCR microservice.
- FastAPI + uvicorn instead of Sanic.

[Unreleased]: https://github.com/dliting/Bishon/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/dliting/Bishon/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/dliting/Bishon/releases/tag/v2.0.0
