# 更新日志

本项目所有显著变更均记录在本文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，并遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

English | [简体中文](CHANGELOG.zh-CN.md)

> 本文件是 [CHANGELOG.md](CHANGELOG.md) 的中文镜像。条目内容与英文版一一对应；如两者不一致，以英文版为准。

---

## [Unreleased]

### 新增
- **`/api/health` 新增 GPU / CUDA 可用性探针。** 在 `ServiceStatusStore.ALL_SERVICES` 注册新的 `gpu` 服务项，报告 `torch.cuda.is_available()` 或 `paddle.device.cuda.device_count()` 是否能看到可用设备。健康时 detail 含设备名 + CUDA 版本；WSL2 环境下两个框架都报告无设备时，detail 直接指向 `docs/wsl-docker-gpu-pitfall.md`（典型的缺 `/usr/lib/wsl` bind-mount 症状）。两个检查都是**运行时**探针——刻意不用 `paddle.device.is_compiled_with_cuda()`，因为它在 GPU 运行时不可用时仍返回 True（误报）。把 WSL2 docker GPU 回归问题暴露到监控里，避免 Rerank/FAISS-GPU/PaddleOCR-GPU 静默回退到 CPU 还发现不了。新增 7 个单元测试在 `tests/backend/unit/monitoring/test_service_probes.py`。
- **python-env 独立打包。** `make-release.sh` 现在产出 `bishon-pyenv-<ver>.tar.gz` 作为独立 tarball（~7 GB），不再将 python-env 打入主 release tarball。主 `bishon-release-<ver>.tar.gz` 变为纯源码包（~2 MB）。`install.sh` 首次安装需 `--pyenv <tar>`；`upgrade.sh` 接受 `--pyenv <tar>` 升级 Python 依赖（overlay + 备份方式）。`--skip-env` 重命名为 `--skip-pyenv`。与 models/node 已有的独立打包模式一致，大幅减小代码增量升级包体积。
- **发布包操作规范**（`docs/release-ops.md`）。文档化发布包的制作、传输、保留和部署标准流程。核心规则：发布包按版本号子目录组织，不覆盖已有版本。

### 变更
- **容器挂载点重命名：`/opt/bishon-data` → `/opt/bishon-home`。** "data" 不准确——该目录包含代码、env、模型和配置，不只是数据；"home" 更贴切。影响 `launcher.sh`（需重打镜像）、`entrypoint.sh`、`start.sh`、`Dockerfile.cuda`、向导默认值及所有文档。宿主机 `--host-dir` 由用户指定，不受影响。

### 修复
- **WSL2 GPU 直通——`nvidia-smi` 正常但容器内 `torch.cuda.is_available()` 返回 `False`。** 根因：`nvidia-container-runtime` 在 cherry-pick WSL 驱动文件时漏掉了 `libnvdxgdmal.so.1`（DXG DMA 助手）。少了它，WSL 的 `libcuda.so.1` 代理第一次 `cuInit()` 就返回 `Error 500: named symbol not found`——容器内 Rerank / FAISS-GPU / PaddleOCR-GPU 静默回退到 CPU，而 `nvidia-smi` 仍正常显示 GPU。修复：`scripts/docker/start.sh` 在 WSL 环境下（`grep -qi microsoft /proc/version`）自动 bind-mount `-v /usr/lib/wsl:/usr/lib/wsl:ro`。原生 Linux 部署不受影响。完整记录见 `docs/wsl-docker-gpu-pitfall.md`。
- **容器 CUDA base 与 torch/paddle wheel 对齐。** `docker/Dockerfile.cuda` 基础镜像从 `nvidia/cuda:12.1.0-runtime-ubuntu22.04` 升级到 `nvidia/cuda:12.6.3-runtime-ubuntu22.04`，匹配 torch 2.12+cu126 / paddlepaddle-gpu cu126。驱动要求：原生 Linux ≥525（CUDA 12.x）；WSL2 需对应的 Windows NVIDIA 驱动 ≥555.x（CUDA 12.6 在 WSL 上的最低支持版本）。注：单做这一项**不能**修上面的 WSL2 GPU 问题——真正生效的是 `/usr/lib/wsl` 那个 bind-mount。

## [2.2.0] - 2026-08-02

### ⚠️ 升级须知（v2.1 → v2.2）
- **一次性镜像重打**才能用上 entrypoint bind-mount 能力（launcher 模式）。旧 v2.1 镜像仍可与 v2.2 release 包配合使用，但失去"升级 entrypoint 逻辑不必重打镜像"的能力。运行一次 `bash scripts/docker/build-image.sh --version <新版本>`，然后 `docker save` 后照常走 `install.sh` / `upgrade.sh` 流程。
- 一次性重打后，**之后所有 entrypoint 改动都走 release tarball 分发**——entrypoint / Node / 前端重构逻辑的升级都不再需要重打镜像。

### 新增
- **根目录 `deploy.sh` —— 4 步交互式部署入口**。一条命令（`bash deploy.sh`）覆盖三种模式：`docker-online`（从 ghcr.io / 阿里云拉镜像）、`docker-offline`（从本地 tar 加载镜像）、`bare-metal`（无 Docker）。`--non-interactive` + 每个问题对应一个 flag，方便 CI/批量部署；`--dry-run` 走完所有步骤但不实际执行。检测到原生 Windows 会建议改用 WSL2。Bundle 自感知：自动识别脚本旁的 `bishon-release-*.tar.gz` 并据此调整默认值。把选择持久化到 `<host-dir>/deploy.conf`，下次运行作为默认（`--dry-run` 时跳过）。
- **`scripts/common/wizard.sh`** —— 交互式参数收集模块，被根 `deploy.sh` source 执行。实现 4 步带序号的流程（模式 → 输入 → 输出 → 确认），以及 `ask` / `ask_required` / `ask_path` / `ask_choice` / `glob_bundle` 等辅助函数。本身不做分发，只设置变量；分发逻辑在 deploy.sh 里直接调 L1 install/start 脚本。
- **四个根 wrapper —— `start-docker.sh`、`stop-docker.sh`、`start-bare-metal.sh`、`stop-bare-metal.sh`**，每个都是 3 行 `exec bash scripts/<mode>/<verb>.sh "$@"`。模式直接体现在文件名里，消除了之前 `start.sh` 在不同目录下含义不同的歧义。
- **启动脚本里加了日志路径提示**。健康检查通过后，`scripts/docker/start.sh` 和 `scripts/bare-metal/start.sh` 都会打印一段简短信息，列出 Web/API 地址、日志文件路径（容器、应用 debug 日志、问答日志）以及停止/升级命令。运维同学不用再去 `docs/` 里 grep 找日志了。
- **`scripts/docker/publish-image.sh`** —— 手动一次性把本地镜像推到 ghcr.io 和/或阿里云镜像仓库。`--registry ghcr|aliyun|both`（默认 both），`--vpc` 切换阿里云到 VPC 内网端点（阿里云 ECS 走内网更快），`--no-latest` 跳过 `:latest` tag。只有当 `~/.docker/config.json` 里没有现成登录时才读 `$GHCR_TOKEN` / `$ALIYUN_PWD`。
- **`scripts/docker/install.sh --pull` / `--registry`** —— 在线拉镜像。内置知名 registry：`ghcr`（`ghcr.io/dliting`）、`aliyun`（`crpi-cpr1xsemy1pzwjoc.cn-beijing.personal.cr.aliyuncs.com/dliting`）、`aliyun-vpc`（VPC 内网端点）。也支持自定义 URL。
- **`scripts/common/preflight.sh --mode`** —— `release`（默认） | `docker-online` | `docker-offline` | `bare-metal`。Docker 镜像检查按模式调整（bare-metal 完全跳过；docker-online 只检查 Docker 是否可用）。还新增了 `--src-only` 子模式，给 release 打包用。
- **`scripts/common/download-models.sh`** —— 给新开发/部署同学用的幂等模型下载脚本。默认走 `hf-mirror.com`（HuggingFace 国内镜像）；PaddleOCR 模型通过 `paddleocr` 包自动拉取。Flags：`--target`、`--dry-run`、`--offline <tar>`、`--skip-rerank`、`--skip-paddleocr`。读取 `HF_ENDPOINT`、`RERANK_REPO`、`BISHON_PY` 环境变量。
- **模型 tarball 独立打包**：`make-release.sh` 现在额外产出一个 `bishon-models-<ver>.tar.gz`，和主 release tarball 分开。`install.sh --models <tar>` 可选接收 —— 不带模型也能装（Rerank 关闭，OCR 启动时告警）。
- **`make-release.sh --skip-pyenv --skip-models --skip-image`**（v2.2.0 由 `--skip-env` 重命名）：三个 skip 都加上时，5 秒内产出一个仅含源码的小 tarball，方便快速验证打包流程。不用每次都等 12 GB 的 env/models/image 拷贝。
- **SHA256 校验**：每个 tarball 现在都附带 `.sha256`，部署侧可以校验完整性。
- **`bishon-cuda:latest` tag**：`build-image.sh` 现在同时打 `latest` tag，方便 CI/自动化。
- **GPU 冒烟测试（`tests/backend/integration/test_gpu_smoke.py`）** —— 5 个用例验证 torch + FAISS + Qwen3-Reranker 在装好后都能看到 GPU。CPU-only 机器上自动 skip。能抓出 torch+cu130 vs driver-CUDA-12.6 不匹配这种"GPU 静默用不了"的问题。
- **支持 `faiss-gpu-cu12` pip wheel** —— `requirements.txt` 现在写明了 GPU 路径（`pip install faiss-gpu-cu12`，需先卸载 `faiss-cpu`），不再写"GPU 版本需通过 conda 安装"。

### 修复
- **import 时机导致 `.env` 未生效**。`bishon_kernel/__init__.py` 现在在任何子模块导入前先 `load_dotenv` —— connector 模块（`llm_for_openai_api`、`openai_embedding`）在 import 时就捕获 `os.getenv` 结果，任何模块先于 `model_config` 的 `load_dotenv` 被导入都会拿到 `None`/默认值。这是 LLM probe 报 `no API base URL configured`、embedding probe 无视 `.env` 指向 localhost 的根因。
- **probe 补上鉴权头**。`probe_llm` 对非 ollama provider 发送 `Authorization: Bearer <key>`（讯飞 MaaS 的 `GET /v1/models` 强制要求）；`probe_embedding` 在 `EMBEDDING_API_KEY` 已设置且不等于 `EMPTY` 时发送 Bearer。
- **`probe_sqlite` 改为新开连接**。`KnowledgeBaseManager` 本来就是一次性连接，probe 现在 `sqlite3.connect(DB_PATH)` + `SELECT 1`，不再找那个从不存在的持久 `kb_manager.conn`。
- **OCR GPU 检测与实际 paddle 构建匹配**。`can_use_ocr_gpu` 现在检查 `paddle.device.is_compiled_with_cuda()` 而非只信 `OCR_USE_GPU`；当请求 GPU 但 paddle 是 CPU 构建时，`local_doc_qa` 降级到 CPU 并告警，而不是把虚假的 GPU 参数传进 PaddleOCR。
- **测试隔离：后台 `_safe_insert` 不再越过 fixture 清理**。`tests/backend/integration/conftest.py::api_client` 现在在 `tmp_path` 清理之前先 drain `handler._executor` —— 之前队列里的 `_safe_insert` 会和 pytest 的 tmp_path 删除赛跑，触发 `sqlite3.OperationalError: no such table: File`（SQLite 把空文件当成新库自动建）。测试套件从 `1 error` 变成 `0 errors`（244 passed）。

### 变更
- **`scripts/` 重组为三层结构**：`scripts/common/`（共享工具——`utils.sh`、`wizard.sh`、`preflight.sh`、`validate-manifest.sh`、`download-models.sh`）、`scripts/docker/`（仅 Docker——`install.sh`、`start.sh`、`stop.sh`、`upgrade.sh`、`uninstall.sh`、`build-image.sh`、`publish-image.sh`、`make-release.sh`）、`scripts/bare-metal/`（仅裸机——`start.sh`、`stop.sh`）。取代了之前的 `scripts/docker/lib/` 共享 helper 布局。**不向下兼容** —— v2.1.x 既有部署需要重新 clone 或更新脚本路径。
- **删除 L2 编排层**。`scripts/docker/deploy-docker.sh` 和 `scripts/docker/deploy-bare-metal.sh` 已删除；分发逻辑（mode → install/start 调用链）现在内联在根 `deploy.sh` 的 `case "$MODE"` 里，约 30 行。
- **重命名以提高可读性**。
  - `scripts/docker/build.sh` → `scripts/docker/build-image.sh`（之前和 `make-release.sh` 容易混淆）。
  - `scripts/docker/publish.sh` → `scripts/docker/upgrade.sh`（publish 是发布打包的意思，不是原地升级）。
  - `scripts/docker/lib/common.sh` → `scripts/common/utils.sh`。
  - `scripts/docker/{preflight,validate-manifest}.sh` → `scripts/common/`。
  - `scripts/download-models.sh` → `scripts/common/download-models.sh`。
  - `scripts/{start,stop}.sh` → `scripts/bare-metal/{start,stop}.sh`。
- **`bishon-env/` 改名为 `python-env/`**（host-dir 布局）。**Breaking change** —— v2.1.x 既有部署需要重跑 install。受影响文件：`entrypoint.sh`、`Dockerfile.{cuda,ascend}`、`install.sh`、`make-release.sh`、`preflight.sh`、`docs/deployment.md`。（CHANGELOG 在 [2.1.0] 段保留历史引用。）
- **`build-image.sh` / `make-release.sh`** 的 `--version` 默认值改为读取 repo 根的 `VERSION` 文件。项目级的单一真实来源；`--version <ver>` 仍可覆盖。
- **`make-release.sh` bundle 布局**：现在拷贝整个 `scripts/{common,docker,bare-metal}` 子树 + 根 `deploy.sh`（之前只拷 `scripts/docker/.` + 用 heredoc 生成 deploy wrapper）。Bundle 用户拿到的 `deploy.sh` 体验和开发者 clone 一致。
- **`make-release.sh --force` 语义**：基于 rsync 的原地覆盖（只替换变化过的文件）。不再 `rm -rf`。`--merge` flag 删除（语义和 `--force` 重叠）。
- `make-release.sh` pre-flight 检查重构为委托给 `preflight.sh`（单一真实来源）。
- `download-models.sh --dry-run` 现在反映真实文件系统状态：已存在的目录打印"would skip"而不是无条件"would download"。
- `deploy.conf` 保存现在显式由 `! $DRY_RUN` 把关 —— 之前默认开启的 `--save-config` 在 `--dry-run` 下也会写文件，破坏了 dry-run "无副作用"的契约。

### 移除
- `scripts/docker/deploy.sh`（移到 repo 根，重写为 wizard 入口）。
- `scripts/docker/deploy-docker.sh`（L2 模块；分发逻辑合并到根 `deploy.sh`）。
- `scripts/docker/deploy-bare-metal.sh`（L2 模块；分发逻辑合并到根 `deploy.sh`）。
- 根 `start.sh` 和 `stop.sh`（由四个模式特定的 wrapper 取代）。
- 所有 Windows `.bat` wrapper（Windows 主机上的 WSL2-only 策略；`.bat` 文件本身就半残，还诱导用户走不支持的路径）。
- `scripts/docker/lib/` 目录（helper 迁到 `scripts/common/`）。
- `make-release.sh --merge` flag（用 `--force`）。
- `scripts/docker/deploy-entry-wrapper.sh.in`（bundle 现在直接带真正的根 `deploy.sh`）。

### 文档
- `docs/deployment.md` —— 在生命周期章节顶部加了**快速参考表**：每行一个操作（部署/启动/停止/升级/卸载/日志）× 每列一种模式（Docker 离线 / Docker 在线 / 裸机）。运维几秒就能找到对应命令，不用读散文。
- `docs/deployment.md` 重排：开头改为 wizard 入口 + 三模式对比表；老脚本降级为"高级用法"。
- `README.md` —— 项目布局块更新为 `deploy.sh` + 四个根 wrapper + `scripts/{common,docker,bare-metal}/` 树（之前是两个根 wrapper + 扁平的 `scripts/`）。
- `README.md` Quick Start：新增第 5 步"Download model weights"，指向 `scripts/common/download-models.sh`。
- `docs/dev-environment.md`：文档化下载脚本的 flags 和 env vars；澄清 `--target` 只影响 Reranker 路径（PaddleOCR 路径由 `model_config.py` 硬编码）。
- `docs/deployment.md` "前置条件"：澄清三种获取模型的方式（脚本在线下载、tarball 离线、或预置目录拷贝）。

### 测试
- `tests/scripts/test_deploy.bats`（从 `test_bishon_deploy.bats` 改名）：16 个用例覆盖 wizard 语法/风格、`--help`、`--non-interactive --dry-run` 三模式、未知 mode 拒绝、dry-run 无副作用契约（I1 回归）、平台检测（`--native-windows`）、配置持久化把关。所有调用都加 `--native-windows` 跳过 CI 里的 WSL-only 检查。
- `tests/scripts/test_download_models.bats`：9 个用例覆盖语法、防御式风格、`--help`、`--dry-run`、`--offline` tarball 解压、幂等性、`HF_ENDPOINT` 覆盖、未知 flag 退出码。
- `tests/scripts/test_docker_scripts.bats`：16 个用例 —— 路径更新到 `common/` 拆分后的位置（validate-manifest、utils）。
- `tests/scripts/test_start_sh.bats`：6 个用例 —— 现在测全部四个根 wrapper（`start-docker`、`stop-docker`、`start-bare-metal`、`stop-bare-metal`）。
- Bats 套件总数：**29 → 47 用例**。

### 运维
- Git 流程：引入 `dev` 分支做日常开发；`main` 留给 tagged release。CI 现在在 `main` + `dev` 的 push 上触发。
- 本地 worktree 布局文档化：`I:\Bishon\V2\{main,dev}\`（Windows junction）+ `/opt/Bishon/V2/{main,dev}/`（WSL ext4 符号链接），共享 `models-shared/` 避免两份 2.5 GB。

## [2.1.0] - 2026-07-29

### 新增
- **离线 Docker 部署**（`bishon-cuda:<version>` 镜像 + release tarball 工作流）。完整运维流水线：`build.sh` → `make-release.sh` → `install.sh` → `start.sh` → `publish.sh`（升级） → `uninstall.sh`。见 `docs/deployment.md`。
- **Docker 镜像 `bishon-cuda:2.1.0`**（约 3 GiB）：CUDA 12.1 runtime + Ubuntu 22.04 + tzdata + miniconda3 base（env 通过 bind mount + entrypoint 符号链接在运行时注入）。
- **`docker/Dockerfile.ascend`** 占位，为后续华为昇腾（CANN）镜像变种预留。
- **Release manifest**（`release/MANIFEST`）：明确白名单列表，列出 release tarball 里要带的路径。替代之前的"rsync 全部 + 排除清单"模式。
- **`scripts/docker/lib/common.sh`**：共享 helper（`bishon_log`、`bishon_die`、`bishon_warn`、`bishon_parse_manifest`、`bishon_validate_host_dir_fs`）—— 日志格式和部署期文件系统安全检查的单一真实来源。
- **`scripts/docker/validate-manifest.sh`**：独立工具，审计 `release/MANIFEST`；可由人/bats 测试/CI 调用。
- **`scripts/ci/shell-checks.sh`**：可移植的 shell 端 CI 逻辑（bash -n、MANIFEST 校验、bats 测试）。把 CI 逻辑从 CI 平台语法（GitHub Actions / GitLab CI / Gitea / Jenkins）解耦。见 `docs/ci.md`。
- **`scripts/ci/install-bats.sh`**：可选的系统级 bats 安装器（apt → brew → 源码编译）。
- **vendored bats-core v1.2.1**（MIT）。让 CI 不联网也能跑 shell 检查 —— 对内部没 apt 镜像的 CI runner 很重要。
- **Bats 测试覆盖**：`tests/scripts/test_docker_scripts.bats`（16 用例）+ `tests/scripts/test_start_sh.bats`（4 用例）。覆盖每个部署脚本的语法/风格、manifest 解析器、文件系统安全检查（拒绝 `/mnt/*`、`/media/*`、`/run/media/*` 和已知有问题的 fs 类型），以及独立的 validate-manifest 工具。
- **`docs/dev-environment.md`**：WSL ext4 + models 符号链接工作流，附"SQLite WAL 需要 shm vs 只读二进制权重"的理由说明。
- **`docs/ci.md`**：CI 可移植性设计 —— 从 GitHub Actions 迁到 GitLab CI / Gitea / Jenkins 时，什么保留、什么重写。
- **`docs/deployment.md`**：300 行运维指南，覆盖前置条件、镜像构建、release 打包、install、start、upgrade、uninstall，以及 Docker 避坑指南对照（host.docker.internal、9p 上的 SQLite WAL、UTC 时区、publish 覆盖、部署后验证）。
- **README.md "Docker deployment (optional)" 段**，附端到端命令示例和 `docs/deployment.md` 链接。
- **`CHANGELOG.md`** v2.1.0 段（本条目）。
- **CI shell job** 在 `.github/workflows/ci.yml`，和 backend（Python 3.11/3.12）、frontend（Node 20）job 并列。

### 变更
- **Entrypoint 把 BISHON_DB/logs** 从源码相对路径重定向到 `/opt/bishon-home/` 根（通过符号链接）。修两个潜在问题：(1) publish 替换 `bishon/` 会清掉用户数据；(2) WSL `/mnt/*` 源码目录通过 9p/NTFS 触发 SQLite WAL I/O 错误。
- **`.env` 通过 `docker run --env-file` 注入**，配置文件位于 `/opt/bishon-home/.env`（publish 安全的 source 同级），同时 `model_config.py` 的 `load_dotenv(root_path/.env)` 作为 no-op 保留。
- **`build.sh` 体积输出**：把老 Docker 上不可用的 `divf` Go 模板函数换成 awk。
- **`Dockerfile.cuda` miniconda 下载**：多源 fallback（清华镜像优先，官方次之），应对国内网络环境。
- **`Dockerfile.cuda` HEALTHCHECK `start-period`**：120s → 180s，匹配 `start.sh` 的轮询窗口。
- **`install.sh` `/mnt/*` 检查**扩大到也拒绝 `/media/*`、`/run/media/*`（Linux 自动挂载点）。
- **`install.sh` 和 `publish.sh`** 现在用 `mktemp -d -p "$HOST_DIR"`，保证 staging 目录和目标在同一文件系统上，从而在被打断的 publish/install 上也能保证 atomic rename(2)。
- **`start.sh` `/bishon/` 非 200 直接失败**：缺前端资源现在大声失败，而不是悄悄上线一个坏 UI。
- **`start.sh` `--gpus all` 在 NVIDIA Container Toolkit 未注册时立刻失败**（避免 180s 健康检查超时带来的困惑）。
- **`make-release.sh` MANIFEST 驱动**，不再用 rsync-with-excludes。一眼就能审计要发什么。
- **`make-release.sh` pre-checks**：bishon env 导入（torch/faiss/paddle/transformers/langchain）、WSL Ubuntu 版本匹配（22.04）、`bishon_kernel/bishon_server/dist/bishon/index.html` 存在、`models/paddleocr_models/` 至少 4 个子目录。
- **`publish.sh` pre-flight** 也检查 `.image-tag` 和 `bishon-env/bin` —— 失败时有清晰报错，而不是让下游 `start.sh` 莫名失败。
- **所有部署脚本迁移**到共享的 `bishon_log` / `bishon_die`，通过 `BISHON_LOG_TAG=<tag>` 区分。日志格式的单一真实来源；错误消息里 tag 处理一致。
- **`run_all_tests.sh` 自动发现** `tests/scripts/*.bats`，不再硬编码文件名。
- **`requirements.txt` 第 1 行注释**更新：`无 Docker 依赖` → `主进程不依赖 Docker；离线 Docker 部署见 docs/deployment.md`。
- **`.github/workflows/ci.yml` 的 `npm ci`** 现在带 `--legacy-peer-deps`，绕过 pinia peer-dep 冲突（计划 v2.2 升级）。
- **`CLAUDE.md`**（本地、gitignored）增加"工作目录与符号链接原则（WSL）"段。

### 修复
- 多处 ruff lint 警告：FastAPI/uvicorn 必须 sys.path 操作之后的导入加 `# noqa`（E402）；FastAPI multipart-default 写法（B008）；`zip(..., strict=False)` 符合 PEP 618（Python 3.10+）；未使用循环变量改为 `_key` 约定；f-string 替代 `%` 格式化。
- `tests/scripts/test_start_sh.sh` 改名为 `test_start_sh.bats`，让新 `run_all_tests.sh` 的 glob 能重新发现（之前测试 runner 重构时被悄悄漏掉）。

### 安全
- `uninstall.sh` 即使加 `--purge-data` 也拒绝 `rm -rf` —— 运维必须手动 `rm -rf <host-dir>`。避免路径参数打错带来的灾难性数据丢失。

### 文档
- `README.md` Roadmap 更新：v2.1（Docker）标记为当前；v2.2 列了多模态接入、可插拔存储、Ascend 镜像。
- `NOTICE` 现在列出内嵌的第三方源码（bats-core v1.2.1，MIT）。
- `.gitattributes` 把 LF 强制扩展到 `*.bash`。

### 运维
- 端到端验证：镜像构建（2.9 GiB）、容器冷启动 12 秒、SQLite WAL 在 ext4 上正常工作（journal_mode=wal，busy_timeout=5000）、KB 创建/列表/持久化全过。对真实 release tarball 的冒烟测试（`make-release.sh` → `install.sh` → `start.sh`）通过。

## [2.0.0] - 2026-07-07

### 新增
- Bishon V2 首次公开发布。
- 本地优先的知识库问答系统：FastAPI + FAISS + SQLite + PaddleOCR + 进程内 Rerank。
- Vue 3 + Vite + TypeScript + Ant Design Vue 前端，支持 SSE 流式问答。
- 多格式文档接入：PDF、Word（docx）、PPT、TXT、图片（jpg/png/jpeg）、CSV、Excel、EML、Markdown、网页 URL。
- 文档溯源：点击任一来源文档可在浏览器打开原始文件。
- 健康检查端点（`GET /api/health`），用于部署探针。
- MIT 许可证、CONTRIBUTING、CODE_OF_CONDUCT、SECURITY 政策。

### 架构
- 取代了原始的 Docker Compose 技术栈（Milvus + etcd + MinIO + Elasticsearch + MySQL + Triton），改为单进程部署。
- FAISS（文件持久化）替代 Milvus。
- SQLite（WAL 模式）替代 MySQL。
- SQLite FTS5（默认关闭）替代 Elasticsearch。
- 外部 OpenAI 兼容 HTTP API 提供 LLM 和 Embedding（Ollama / vLLM / OpenAI）。
- 进程内 Qwen3-Reranker（transformers）替代 Triton rerank 微服务。
- 进程内 PaddleOCR 3.x 替代 OCR 微服务。
- FastAPI + uvicorn 替代 Sanic。

[Unreleased]: https://github.com/dliting/Bishon/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/dliting/Bishon/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/dliting/Bishon/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/dliting/Bishon/releases/tag/v2.0.0
