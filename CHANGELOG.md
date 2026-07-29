# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_No unreleased changes._

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
