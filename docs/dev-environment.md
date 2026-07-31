# Bishon V2 开发环境搭建

本文档说明在 Windows + WSL2 上搭建 Bishon V2 开发环境的标准流程，覆盖：
- 在 WSL ext4 上工作（不是 `/mnt/i/...`）
- 哪些目录必须留 ext4、哪些可以符号链接到 Windows
- bare-metal 启动 + 镜像构建 + 离线包制作的完整开发循环

如果是 Linux 服务器或 macOS 直接开发，本文档的"ext4 vs 9p"权衡不适用，可以忽略。

## 为什么代码要在 WSL ext4 上

WSL2 访问 Windows 文件系统（`/mnt/c`、`/mnt/i` 等）走 9p 协议，对**小文件密集型**操作（Python import、SQLite WAL、git status）有显著的元数据开销；对 SQLite 的 WAL 模式还有兼容性问题（依赖共享内存 `shm_open` 与可写 `mmap`，9p 不支持），会触发 I/O 错误让进程崩溃。

把仓库 clone 到 WSL ext4（如 `/opt/Bishon/V2` 或 `~/projects/Bishon`）后：

- Python import、`pip install -e .`、pytest 等都跑在原生 ext4 上，速度与原生 Linux 相当。
- SQLite WAL 工作正常。
- `bash run_all_tests.sh` 全绿。

但仓库里有些目录是**只读二进制**（模型权重），用符号链接共享到 Windows 更合理（避免在 WSL 占 2.5 GB）。下面具体说明。

## 推荐目录布局

```
/opt/Bishon/V2/                    ← ext4（源码 + 数据）
├── bishon_kernel/                 ← 源码（编辑快）
├── front_end/                     ← 源码
├── tests/, docs/, docker/, ...    ← 其他源码
├── BISHON_DB/                     ← SQLite + FAISS + 上传内容（必须 ext4，写密集 + WAL）
├── logs/                          ← 日志写入（必须 ext4）
├── .env                           ← 配置（gitignored）
├── CLAUDE.md                      ← 本地约束（gitignored）
└── models -> /mnt/i/Bishon/V2/models   ← 符号链接到 Windows（节省 2.5 GB）
```

**判断原则**：

| 类型 | 例子 | 放哪 |
|---|---|---|
| 写密集 + 需共享内存/可写 mmap | SQLite (`BISHON_DB/metadata.db`)、FAISS 索引 | **必须** ext4 |
| 写密集 + 小文件 | 日志（`logs/`） | ext4 |
| 读密集 + 小文件 + 多次访问 | 源码（`bishon_kernel/`、`front_end/`） | ext4（速度优先） |
| 读一次 + 大二进制 + 只读 mmap | 模型权重（`models/*.safetensors`、`*.pdiparams`） | **符号链接**到 Windows（空间优先） |
| 配置 | `.env` | ext4（避免 publish 覆盖；WSL 内编辑也快） |

> 模型权重选择符号链接的关键：PaddleOCR / Reranker 加载时只对 `.pdiparams` / `.safetensors` 文件做**只读 mmap**，没有共享内存或可写 mmap 的需求。9p 对只读 mmap 是支持的（启动时多读 30-60 秒可接受），但对 `shm_open` 和可写 mmap 不支持。SQLite WAL 同时依赖这两者——所以 BISHON_DB 不能跨 9p，但 models 可以。

## 从零搭建（一次性）

### 1. WSL Ubuntu 22.04

必须是 22.04 — 与 Docker 镜像 base 一致（glibc 兼容性）。

```bash
# 在 Windows PowerShell
wsl --install -d Ubuntu-22.04
```

### 2. miniconda3 + bishon env

```bash
# 在 WSL
wget https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p /opt/miniconda3
echo 'source /opt/miniconda3/etc/profile.d/conda.sh' >> ~/.bashrc
source ~/.bashrc

conda create -n bishon python=3.11 -y
conda activate bishon
pip install -r /path/to/requirements.txt
```

### 3. clone 仓库到 ext4

```bash
mkdir -p /opt/Bishon
git clone git@github.com:dliting/Bishon.git /opt/Bishon/V2
cd /opt/Bishon/V2
```

如果 GitHub SSH 不通，把 Windows 端 `~/.ssh/id_ed25519` 拷到 WSL `~/.ssh/` 并 `chmod 600`。

### 4. 迁移运行时依赖（一次性，仅当你已有 Windows 端工作目录时）

```bash
# 假设 Windows 端工作目录是 /mnt/i/Bishon/V2，且其中已有 .env / models / dist 等
SRC=/mnt/i/Bishon/V2
DST=/opt/Bishon/V2

# 配置（小文件，直接 cp）
cp "$SRC/.env" "$DST/.env"
cp "$SRC/CLAUDE.md" "$DST/CLAUDE.md"   # 本地约束，不入库

# 前端构建产物（4 MB，直接 cp）
mkdir -p "$DST/bishon_kernel/bishon_server"
cp -r "$SRC/bishon_kernel/bishon_server/dist" "$DST/bishon_kernel/bishon_server/dist"

# 历史数据（如果有价值保留）
cp -r "$SRC/BISHON_DB" "$DST/BISHON_DB"

# models：用符号链接，不复制（节省 2.5 GB）
ln -s "$SRC/models" "$DST/models"
```

如果是从零开始（无 Windows 端工作目录）：

```bash
# .env 从模板创建
cp .env.example .env
# 编辑 .env：OPENAI_API_BASE、EMBEDDING_API_BASE 等

# 前端构建
cd front_end && npm ci --legacy-peer-deps && npm run build && cd ..
cp -r front_end/dist bishon_kernel/bishon_server/

# 下载模型（Qwen3-Reranker 0.6B ~1.2 GB + PaddleOCR v3 ~100 MB）
bash scripts/common/download-models.sh
# 或先 dry-run 看源：
# bash scripts/common/download-models.sh --dry-run
```

`scripts/common/download-models.sh` 默认从国内 HuggingFace 镜像（`hf-mirror.com`）拉 Reranker，触发 PaddleOCR 自动下载。脚本支持：
- `--target <dir>` 自定义模型目录（默认 `./models`）
- `--skip-rerank` / `--skip-paddleocr` 跳过其中一个
- `--offline <tar.gz>` 从已有的 models tarball 解压（内网部署用）
- `--dry-run` 仅打印下载源，不实际下载

> **注意**：`--target` 只影响 Qwen3-Reranker 的下载位置。PaddleOCR 模型由 `paddleocr` 包按 `bishon_kernel/configs/model_config.py` 推导的路径（`<repo-root>/models/paddleocr_models/`）放置，与 `--target` 无关——这是应用代码的硬约束。如需把整套模型放到别处，建议符号链接 `models/` 整目录而不是改 `--target`。

环境变量：
- `HF_ENDPOINT` 自定义 HuggingFace 镜像（默认 `https://hf-mirror.com`）
- `RERANK_REPO` 自定义 Reranker 仓库 ID（默认 `Qwen/Qwen3-Reranker-0.6B`）
- `BISHON_PY` bishon conda env 的 python 路径（默认 `/opt/miniconda3/envs/bishon/bin/python`）

### 5. 验证

```bash
cd /opt/Bishon/V2

# 文件系统是 ext4
df -T .

# 模型通过符号链接可达
ls -la models
ls models/paddleocr_models/   # 应有 det/rec/cls/doc_ori
ls models/Qwen3-Reranker-0.6B/

# 启动 bare-metal
bash start.sh
# 在另一个终端
curl http://localhost:8777/api/health
curl http://localhost:8777/bishon/

# 关闭
pkill -f "uvicorn bishon_kernel"
```

## 日常开发循环

### 编辑代码

源码在 `/opt/Bishon/V2/`（ext4）。三种编辑方式：

1. **WSL 终端 + vim/nano**：最直接，无任何转换开销。
2. **VS Code Remote-WSL**：在 VS Code 里 `Remote-WSL: Open Folder in WSL...` 选 `/opt/Bishon/V2`。VS Code 后端进程跑在 WSL 内，前端跑在 Windows，体验丝滑。
3. **Windows IDE 直接编辑 `/mnt/wsl/...`**：可行但慢，**不推荐**（小文件 9p 开销大）。

### 编辑模型

模型在 `/mnt/i/Bishon/V2/models/`（Windows 端），从 WSL 通过 `/opt/Bishon/V2/models` 符号链接访问。如果替换/添加模型：

- 直接在 Windows 端操作（资源管理器、git lfs pull）
- WSL 端通过符号链接自动可见，无需同步

### 切换分支 / 拉取

```bash
cd /opt/Bishon/V2
git fetch
git checkout <branch>
# 如果前端有变化
cd front_end && npm ci --legacy-peer-deps && npm run build && cd ..
cp -r front_end/dist bishon_kernel/bishon_server/
```

### 跑测试

```bash
cd /opt/Bishon/V2
bash run_all_tests.sh
```

包含后端 pytest、前端 vitest、shell bats、Playwright e2e（要求 backend 在 8777 端口运行）。

### 构建 Docker 镜像 / 制作发布包

见 [`docs/deployment.md`](./deployment.md)。要点：

```bash
# 构建镜像（联网，下载 cuda base + miniconda）
bash scripts/docker/build-image.sh --version 2.1.0

# 制作离线发布包（含 env、源码、模型、镜像 tar）
bash scripts/docker/make-release.sh --version 2.1.0

# 产物在 dist/
ls -la dist/
```

## 常见问题

### Q: 改完代码后 Docker 镜像里跑的还是旧代码？

容器内代码来自 host-dir/bishon/（部署机），与开发机的 `/opt/Bishon/V2` 无关。开发机改动需要走 publish 流程才能进容器：

```bash
# 开发机：重新打包
bash scripts/docker/make-release.sh --version <new>
# 把新 tarball 拷到部署机，再
bash <host-dir>/scripts/upgrade.sh --host-dir <host-dir> --release <new-tar>
bash <host-dir>/scripts/stop.sh  --host-dir <host-dir>
bash <host-dir>/scripts/start.sh --host-dir <host-dir>
```

详见 [`docs/deployment.md` § 部署机：升级](./deployment.md#部署机升级publish)。

### Q: SQLite 还是报 WAL 错误？

检查 `BISHON_DB/` 实际所在文件系统：

```bash
df -T /opt/Bishon/V2/BISHON_DB
# Type 列必须是 ext4（或 btrfs/xfs/zfs 等支持 mmap 的），不能是 9p/drvfs/tmpfs/overlay
```

如果错误地通过符号链接把 `BISHON_DB/` 指向了 `/mnt/...`，删掉符号链接、把数据迁回 ext4。

### Q: 想用 Windows IDE 编辑源码怎么办？

推荐 VS Code + Remote-WSL 扩展。在 VS Code 命令面板选 `Remote-WSL: Open Folder in WSL...`，输入 `/opt/Bishon/V2`。VS Code 自动处理 Windows ↔ WSL 文件路径，编辑体验与本地无异。

不推荐通过 `\\wsl.localhost\...` UNC 路径用其他 IDE 编辑——大文件 OK，但小文件元数据操作慢。
