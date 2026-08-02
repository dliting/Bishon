# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

English | [简体中文](CHANGELOG.zh-CN.md)

## [Unreleased]

### Added
- **GPU / CUDA availability probe in `/api/health`.** A new `gpu` service entry (registered in `ServiceStatusStore.ALL_SERVICES`) reports whether `torch.cuda.is_available()` or `paddle.device.cuda.device_count()` see a usable device. Detail string includes device name + CUDA version when healthy, and on WSL2 specifically points operators to `docs/wsl-docker-gpu-pitfall.md` when both frameworks report no device (the classic missing-`/usr/lib/wsl` bind-mount symptom). Both checks are runtime probes, not compile-time flags — `paddle.device.is_compiled_with_cuda()` is deliberately NOT used because it returns True even when the GPU is unreachable at runtime. Surfaces the WSL2 docker GPU regression in monitoring rather than letting Rerank/FAISS-GPU/PaddleOCR-GPU silently fall back to CPU. Backed by 7 unit tests in `tests/backend/unit/monitoring/test_service_probes.py`.

### Fixed
- **WSL2 GPU passthrough — `nvidia-smi` worked but `torch.cuda.is_available()` returned `False` inside the container.** Root cause: `nvidia-container-runtime` cherry-picks WSL driver files into the container and historically missed `libnvdxgdmal.so.1` (the DXG DMA helper). Without it, the WSL `libcuda.so.1` proxy returns `Error 500: named symbol not found` on the first `cuInit()` call — silently breaking Rerank/FAISS-GPU/PaddleOCR-GPU inside the container while `nvidia-smi` reports the GPU fine. Fix: `scripts/docker/start.sh` now bind-mounts `/usr/lib/wsl:/usr/lib/wsl:ro` when running under WSL (`grep -qi microsoft /proc/version`). Native Linux deployments are unaffected. Full write-up in `docs/wsl-docker-gpu-pitfall.md`.
- **Container CUDA base aligned with torch/paddle wheels.** `docker/Dockerfile.cuda` base bumped from `nvidia/cuda:12.1.0-runtime-ubuntu22.04` to `nvidia/cuda:12.6.3-runtime-ubuntu22.04` to match torch 2.12+cu126 / paddlepaddle-gpu cu126. Driver requirements: native Linux ≥525 (CUDA 12.x); WSL2 needs the matching Windows NVIDIA driver ≥555.x for CUDA 12.6 (Windows release branch R555+). Note: this bump alone did not fix the WSL2 GPU issue above — the bind-mount was the actual fix.

## [2.2.0] - 2026-08-02

### ⚠️ Upgrade Notice (v2.1 → v2.2)
- **One-time image rebuild required** to gain the entrypoint bind-mount capability (launcher pattern). Old v2.1 image still works with v2.2 release bundles but loses the ability to upgrade entrypoint logic without rebuilding the image. Run `bash scripts/docker/build-image.sh --version <new-ver>` once, then `docker save` and ship via `install.sh`/`upgrade.sh` as usual.
- After this one-time rebuild, **all subsequent entrypoint changes ship via release tarball only** — no more image rebuilds for entrypoint/Node/frontend-rebuild logic changes.

### Added
- **Root `deploy.sh` — 4-step interactive wizard entry point.** Single command (`bash deploy.sh`) covers three modes: `docker-online` (pull from ghcr.io or Aliyun), `docker-offline` (load local tar), `bare-metal` (no Docker). `--non-interactive` + flag-per-question for CI/batch deploy; `--dry-run` walks through everything without executing. Detects native Windows and suggests WSL2. Bundle-aware: detects `bishon-release-*.tar.gz` next to the script and adapts defaults. Persists choices to `<host-dir>/deploy.conf` for next-run defaults (skipped under `--dry-run`).
- **`scripts/common/wizard.sh`** — interactive gather module sourced by root `deploy.sh`. Implements 4-step numbered flow (mode → inputs → outputs → confirm) and the `ask` / `ask_required` / `ask_path` / `ask_choice` / `glob_bundle` helpers. No dispatch logic — wizard.sh only sets variables; deploy.sh dispatches directly to L1 install/start scripts.
- **Four root wrappers — `start-docker.sh`, `stop-docker.sh`, `start-bare-metal.sh`, `stop-bare-metal.sh`** — each a 3-line `exec bash scripts/<mode>/<verb>.sh "$@" redirect. Mode is now obvious from the filename, eliminating the prior ambiguity where `start.sh` meant different things depending on directory.
- **Log path hints in start scripts** — after successful health check, both `scripts/docker/start.sh` and `scripts/bare-metal/start.sh` print a short block listing the Web/API URLs, the log file paths (container, app debug log, qa log), and the stop/upgrade commands. Operators no longer need to grep `docs/` to find the logs.
- **`scripts/docker/publish-image.sh`** — manual one-shot push of locally built image to ghcr.io and/or Aliyun registry. `--registry ghcr|aliyun|both` (default both), `--vpc` switches Aliyun to VPC endpoint (faster from Aliyun ECS), `--no-latest` skips `:latest` tag. Reads `$GHCR_TOKEN` / `$ALIYUN_PWD` only if not already logged in via `~/.docker/config.json`.
- **`scripts/docker/install.sh --pull` / `--registry`** — online image acquisition. Baked-in well-known registries: `ghcr` (`ghcr.io/dliting`), `aliyun` (`crpi-cpr1xsemy1pzwjoc.cn-beijing.personal.cr.aliyuncs.com/dliting`), `aliyun-vpc` (VPC endpoint). Supports custom URLs too.
- **`scripts/common/preflight.sh --mode`** — `release` (default) | `docker-online` | `docker-offline` | `bare-metal`. Docker image check is mode-aware (bare-metal skips entirely; docker-online just checks Docker availability). Also gained `--src-only` sub-mode for release-packaging checks.
- **`scripts/common/download-models.sh`**: idempotent model downloader for new developers and deploy hosts. Defaults to `hf-mirror.com` (HuggingFace China mirror); PaddleOCR models auto-fetched via the `paddleocr` package. Flags: `--target`, `--dry-run`, `--offline <tar>`, `--skip-rerank`, `--skip-paddleocr`. Respects `HF_ENDPOINT`, `RERANK_REPO`, `BISHON_PY` env vars.
- **Models tarball separation**: `make-release.sh` now produces `bishon-models-<ver>.tar.gz` as a standalone artifact, separate from the main release tarball. `install.sh --models <tar>` accepts it optionally — install without models is valid (Rerank disabled, OCR warns at startup).
- **`make-release.sh --skip-env --skip-models --skip-image`**: when all three skips are passed, produces a tiny source-only tarball in ~5s for quick publish testing. Useful for iterating on bundle layout without waiting on the 12 GB env/models/image copy.
- **SHA256 checksums**: every tarball now ships with a matching `.sha256` file for deploy-side integrity verification.
- **`bishon-cuda:latest` tag**: `build-image.sh` now also tags the image as `latest` for CI/automation convenience.
- **GPU smoke test (`tests/backend/integration/test_gpu_smoke.py`)** — 5 cases that verify torch + FAISS + Qwen3-Reranker all see the GPU after install. Skipped automatically on CPU-only hosts. Catches the torch+cu130 vs driver-CUDA-12.6 mismatch that previously left GPU silently unused.
- **`faiss-gpu-cu12` wheels supported** — `requirements.txt` now documents the GPU path (`pip install faiss-gpu-cu12` after uninstalling `faiss-cpu`) instead of saying "GPU 版本需通过 conda 安装".

### Fixed
- **Env vars captured at import time (`.env` never loaded).** `bishon_kernel/__init__.py` now calls `load_dotenv` before any submodule import — connector modules (`llm_for_openai_api`, `openai_embedding`) captured `os.getenv` results at import time, so any module imported before `model_config`'s `load_dotenv` got `None`/defaults. Root cause of `no API base URL configured` in the LLM probe and the embedding probe pointing at localhost even though `.env` said otherwise.
- **Probes now send auth headers.** `probe_llm` sends `Authorization: Bearer <key>` for non-ollama providers (xf-yun MaaS requires it on `GET /v1/models`); `probe_embedding` sends Bearer when `EMBEDDING_API_KEY` is set and not `EMPTY`.
- **`probe_sqlite` opens a fresh connection.** `KnowledgeBaseManager` uses one-shot connections, so the probe now does `sqlite3.connect(DB_PATH)` + `SELECT 1` instead of looking for a persistent `kb_manager.conn` that never existed.
- **OCR GPU detection matches the actual paddle build.** `can_use_ocr_gpu` now checks `paddle.device.is_compiled_with_cuda()` instead of trusting `OCR_USE_GPU` alone; when GPU is requested but paddle is a CPU build, `local_doc_qa` falls back to CPU with a warning instead of passing a bogus GPU flag into PaddleOCR.
- **Test isolation: background `_safe_insert` no longer leaks past fixture teardown.** `tests/backend/integration/conftest.py::api_client` now drains `handler._executor` before `tmp_path` cleanup — previously, a queued `_safe_insert` would race with pytest's tmp_path deletion and trigger `sqlite3.OperationalError: no such table: File` when SQLite re-created an empty DB file. Suite went from `1 error` to `0 errors` (244 passed).

### Changed
- **Restructured `scripts/` into a three-layer layout**: `scripts/common/` (shared utilities — `utils.sh`, `wizard.sh`, `preflight.sh`, `validate-manifest.sh`, `download-models.sh`), `scripts/docker/` (Docker-only — `install.sh`, `start.sh`, `stop.sh`, `upgrade.sh`, `uninstall.sh`, `build-image.sh`, `publish-image.sh`, `make-release.sh`), `scripts/bare-metal/` (bare-metal-only — `start.sh`, `stop.sh`). Replaces the old `scripts/docker/lib/` shared-helper layout. No backwards compatibility — existing v2.1.x deployments must re-clone or update their scripts path.
- **Eliminated the L2 orchestrator layer.** `scripts/docker/deploy-docker.sh` and `scripts/docker/deploy-bare-metal.sh` are deleted; the dispatch logic (mode → install/start call sequence) now lives inline in root `deploy.sh`'s `case "$MODE"` block, ~30 lines.
- **Renamed for clarity.**
  - `scripts/docker/build.sh` → `scripts/docker/build-image.sh` (was confused with `make-release.sh`).
  - `scripts/docker/publish.sh` → `scripts/docker/upgrade.sh` (publish means release-packaging, not in-place upgrade).
  - `scripts/docker/lib/common.sh` → `scripts/common/utils.sh`.
  - `scripts/docker/{preflight,validate-manifest}.sh` → `scripts/common/`.
  - `scripts/download-models.sh` → `scripts/common/download-models.sh`.
  - `scripts/{start,stop}.sh` → `scripts/bare-metal/{start,stop}.sh`.
- **`bishon-env/` renamed to `python-env/`** in the host-dir layout. Breaking change — existing v2.1.x deployments must re-run install. Affected files: `entrypoint.sh`, `Dockerfile.{cuda,ascend}`, `install.sh`, `make-release.sh`, `preflight.sh`, `docs/deployment.md`. (CHANGELOG keeps the historical reference under [2.1.0].)
- **`build-image.sh` / `make-release.sh`** now default `--version` to the contents of the `VERSION` file at repo root. Single source of truth for the project; `--version <ver>` still works as override.
- **`make-release.sh` bundle layout**: now copies the full `scripts/{common,docker,bare-metal}` tree + the root `deploy.sh` (was: `scripts/docker/.` only + heredoc-generated deploy wrapper). Bundle operators get the same `deploy.sh` experience as a developer clone.
- **`make-release.sh --force` semantics**: rsync-based overwrite in place (only changed files replaced). No `rm -rf`. `--merge` flag removed (overlapping semantics with `--force`).
- `make-release.sh` pre-flight checks refactored to delegate to `preflight.sh` (single source of truth).
- `download-models.sh --dry-run` now reflects actual filesystem state: prints "would skip" for already-populated dirs instead of unconditionally saying "would download".
- `deploy.conf` save now explicitly gated by `! $DRY_RUN` — previously a default-on `--save-config` could write the file even under `--dry-run`, breaking the "side-effect-free" contract of dry-runs.

### Removed
- `scripts/docker/deploy.sh` (moved to repo root, rewritten as wizard entry).
- `scripts/docker/deploy-docker.sh` (L2 module; dispatch merged into root `deploy.sh`).
- `scripts/docker/deploy-bare-metal.sh` (L2 module; dispatch merged into root `deploy.sh`).
- Root `start.sh` and `stop.sh` (replaced by the four mode-specific wrappers).
- All Windows `.bat` wrappers (WSL2-only policy on Windows hosts; `.bat` files were half-broken and encouraged unsupported usage paths).
- `scripts/docker/lib/` directory (helpers relocated to `scripts/common/`).
- `make-release.sh --merge` flag (use `--force`).
- `scripts/docker/deploy-entry-wrapper.sh.in` (bundle now ships the real root `deploy.sh`).

### Documentation
- `docs/deployment.md` — added a **quick-reference table** at the top of the lifecycle section: one row per operation (deploy/start/stop/upgrade/uninstall/log) × one column per mode (Docker offline / Docker online / Bare-metal). Operators can find the right command in seconds without reading prose.
- `docs/deployment.md` 重排：开头改为 wizard 入口 + 三模式对比表；老脚本降级为"高级用法"。
- `README.md` — project-layout block updated to show `deploy.sh`, the four root wrappers, and the `scripts/{common,docker,bare-metal}/` tree (was: two root wrappers + flat `scripts/`).
- `README.md` Quick Start: new step 5 "Download model weights" pointing to `scripts/common/download-models.sh`.
- `docs/dev-environment.md`: documents the downloader's flags and env vars; clarifies that `--target` only affects Reranker placement (PaddleOCR path is hardcoded by `model_config.py`).
- `docs/deployment.md` "前置条件": clarifies three ways to acquire models (online via script, offline via tarball, or pre-existing dir copy).

### Test
- `tests/scripts/test_deploy.bats` (renamed from `test_bishon_deploy.bats`): 16 cases covering wizard syntax/style, `--help`, `--non-interactive --dry-run` for all three modes, unknown-mode rejection, dry-run side-effect-free contract (I1 regression), platform detection (`--native-windows`), and config-persistence guards. All invocations pass `--native-windows` to skip the WSL-only check in CI.
- `tests/scripts/test_download_models.bats`: 9 cases covering syntax, defensive style, `--help`, `--dry-run`, `--offline` tarball extraction, idempotency, `HF_ENDPOINT` override, and unknown-flag exit code.
- `tests/scripts/test_docker_scripts.bats`: 16 cases — paths updated for the `common/` split (validate-manifest, utils).
- `tests/scripts/test_start_sh.bats`: 6 cases — now exercises all four root wrappers (`start-docker`, `stop-docker`, `start-bare-metal`, `stop-bare-metal`).
- Bats suite totals: **29 → 47 cases.**

### Operational
- Git workflow: introduced `dev` branch for daily development; `main` reserved for tagged releases. CI now triggers on `main` + `dev` pushes.
- Local worktree layout documented: `I:\Bishon\V2\{main,dev}\` (Windows junctions) + `/opt/Bishon/V2/{main,dev}/` (WSL ext4 symlinks), sharing `models-shared/` to avoid duplicating 2.5 GB.

## [2.1.0] - 2026-07-29

### Added
- **Offline Docker deployment** (`bishon-cuda:<version>` image + release tarball workflow). Full operator pipeline: `build.sh` → `make-release.sh` → `install.sh` → `start.sh` → `publish.sh` (upgrade) → `uninstall.sh`. See `docs/deployment.md`.
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
- **`build.sh` size output**: replaced `divf` Go template function (unavailable on older Docker) with awk.
- **`Dockerfile.cuda` miniconda download**: multi-source fallback (Tsinghua mirror first, official second) to handle China network conditions.
- **`Dockerfile.cuda` HEALTHCHECK `start-period`**: bumped 120s → 180s to match `start.sh`'s polling window.
- **`install.sh` `/mnt/*` check** widened to also reject `/media/*`, `/run/media/*` (Linux auto-mount locations).
- **`install.sh` and `publish.sh`** now use `mktemp -d -p "$HOST_DIR"` so the staging dir is on the same filesystem as the destination, guaranteeing atomic rename(2) on interrupted publish/install.
- **`start.sh` `/bishon/` non-200 fails start**: missing frontend assets now fail loudly instead of silently shipping a broken UI.
- **`start.sh` `--gpus all` fails fast** when NVIDIA Container Toolkit isn't registered with Docker (prevents 180s health-check timeout confusion).
- **`make-release.sh` MANIFEST-driven** instead of rsync-with-excludes. Ship content is auditable at a glance.
- **`make-release.sh` pre-checks**: bishon env import (torch/faiss/paddle/transformers/langchain), WSL Ubuntu version match (22.04), `bishon_kernel/bishon_server/dist/bishon/index.html` exists, `models/paddleocr_models/` has ≥4 subdirs.
- **`publish.sh` pre-flight** also checks `.image-tag` and `bishon-env/bin` exist — fail-fast with clear messages instead of letting downstream `start.sh` fail mysteriously.
- **All deploy scripts migrated** to shared `bishon_log`/`bishon_die` via `BISHON_LOG_TAG=<tag>`. Single source of truth for log formatting; uniform tag handling in error messages.
- **`run_all_tests.sh` auto-discovers** `tests/scripts/*.bats` instead of hard-coding filenames.
- **`requirements.txt` line 1 comment** updated: `无 Docker 依赖` → `主进程不依赖 Docker；离线 Docker 部署见 docs/deployment.md`.
- **`.github/workflows/ci.yml` `npm ci`** now passes `--legacy-peer-deps` to work around pinia peer-dep conflict (tracked for upgrade in v2.2).
- **`CLAUDE.md` (local-only, gitignored)** adds "工作目录与符号链接原则（WSL）" section.

### Fixed
- Various ruff lint warnings: `# noqa` annotations on FastAPI/uvicorn imports that must follow sys.path manipulation (E402); FastAPI multipart-default idiom (B008); `zip(..., strict=False)` per PEP 618 (Python 3.10+); unused-loop-variable convention `_key`; f-string instead of `%` formatting.
- `tests/scripts/test_start_sh.sh` renamed to `test_start_sh.bats` so the new `run_all_tests.sh` glob rediscovers it (was silently dropped during the test-runner refactor).

### Security
- `uninstall.sh` refuses `rm -rf` even with `--purge-data` — operator must run `rm -rf <host-dir>` manually. Prevents catastrophic data loss from a mis-typed path argument.

### Documentation
- `README.md` Roadmap updated to mark v2.1 (Docker) as current; v2.2 lists multimodal ingestion, pluggable storage, Ascend image.
- `NOTICE` now lists embedded third-party source (bats-core v1.2.1, MIT).
- `.gitattributes` extends LF enforcement to `*.bash`.

### Operational
- End-to-end validated: image builds (2.9 GiB), container cold-starts in 12s, SQLite WAL works on ext4 (journal_mode=wal, busy_timeout=5000), KB create/list/persist all pass. Smoke test against real release tarball (`make-release.sh` → `install.sh` → `start.sh`) passes.

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

[Unreleased]: https://github.com/dliting/Bishon/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/dliting/Bishon/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/dliting/Bishon/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/dliting/Bishon/releases/tag/v2.0.0
