# Bishon V2 部署指南

本文档说明 Bishon V2 的部署流程。**推荐入口是 `deploy.sh` 向导**，覆盖三种场景：

| 模式 | 适合 | 网络需求 |
|---|---|---|
| `docker-online` | 在线用户，最简（推荐） | 拉镜像 ~3 GB |
| `docker-offline` | 内网部署 | 无（已有镜像 tar） |
| `bare-metal` | 直接 uvicorn，不用 Docker | 无（本地 env + models） |

## 快速开始

```bash
# 在 WSL2 Ubuntu 22.04 终端
cd /opt/Bishon/V2/dev
bash scripts/docker/deploy.sh
```

向导会按场景逐项询问：
1. 部署模式（docker-online / docker-offline / bare-metal）
2. host-dir 或源码目录路径
3. 镜像源（ghcr.io / 阿里云 / 本地 tar）
4. 模型源（在线下载 / 本地 tarball / 跳过）
5. 确认部署

**部署机只需 `--host-dir` 一个参数**（其他从相对路径自动找）。已有镜像/模型会自动跳过下载。配置存到 `<host-dir>/deploy.conf`，下次向导自动读取作为默认值。

### 非交互模式（CI / 批量部署）

```bash
bash scripts/docker/deploy.sh \
    --non-interactive --mode docker-online \
    --host-dir /var/lib/bishon \
    --release bishon-release-2.1.0.tar.gz \
    --registry aliyun --models-source skip
```

`--dry-run` 跑完所有交互只打印计划不执行。

### Windows 用户

Bishon V2 在原生 Windows 上不保证依赖完整（paddlepaddle-gpu Windows wheel 不全）。**推荐 WSL2 + Ubuntu 22.04**：

```powershell
wsl --install -d Ubuntu-22.04
# WSL 内：
cd /mnt/i/Bishon/V2/dev
bash scripts/docker/deploy.sh
```

向导检测到原生 Windows 会提示打开 WSL。`--native-windows` 强制继续（后果自负）。

---

## 老脚本（高级 / 可编程入口）

向导内部调以下原子脚本，也可直接使用：

### 镜像分发（在线用户跳过 make-release + 手动拷贝）

```bash
# 推到 ghcr.io + 阿里云（首次需要 docker login）
bash scripts/docker/publish-image.sh

# 部署机直接 pull（不需要 make-release 镜像 tar）
bash scripts/docker/install.sh \
    --host-dir /var/lib/bishon \
    --release bishon-release-2.1.0.tar.gz \
    --pull --registry aliyun
```

### 离线打包（开发机）

```bash
# --version 默认读 VERSION 文件
bash scripts/docker/build-image.sh                # 构建 bishon-cuda 镜像
bash scripts/docker/make-release.sh                # 打 env + 源码 + models + 镜像 tar
ls dist/
#   bishon-release-<ver>.tar.gz
#   bishon-models-<ver>.tar.gz
#   bishon-cuda-image-<ver>.tar
#   *.sha256
```

### 详细老脚本说明

[老脚本（保留供高级用法参考）](#) — 见下方章节。


开发环境搭建（WSL ext4 + 模型符号链接等）见 [`dev-environment.md`](./dev-environment.md)。

## 快速参考

| 操作 | Docker 离线 | Docker 在线 | Bare-metal |
|---|---|---|---|
| **部署** | `deploy.sh` → docker-offline | `deploy.sh` → docker-online | `deploy.sh` → bare-metal |
| **启动** | `<dir>/scripts/docker/start.sh --host-dir <dir>` | 同左 | `start-bare-metal.sh` |
| **停止** | `<dir>/scripts/docker/stop.sh --host-dir <dir>` | 同左 | `stop-bare-metal.sh` |
| **升级** | `<dir>/scripts/docker/upgrade.sh --host-dir <dir> --release <tar>` | 同左 | `git pull && pip install -r requirements.txt` |
| **卸载** | `<dir>/scripts/docker/uninstall.sh --host-dir <dir>` | 同左 | `rm -rf <dir>` |
| **日志** | `tail -f <dir>/logs/debug_logs/debug.log` | 同左 | `tail -f logs/debug_logs/debug.log` |

## 目录

- [设计概览](#设计概览)
- [前置条件](#前置条件)
- [开发机：构建镜像](#开发机构建镜像)
- [开发机：制作离线发布包](#开发机制作离线发布包)
- [部署机：首次安装](#部署机首次安装)
- [部署机：启动与健康检查](#部署机启动与健康检查)
- [部署机：升级（publish）](#部署机升级publish)
- [部署机：卸载](#部署机卸载)
- [避坑指南对照表](#避坑指南对照表)
- [常见排障](#常见排障)

## 设计概览

**镜像与发布包分离**，两者都可以离线分发：

| 交付物 | 大小 | 内容 |
|---|---|---|
| `bishon-cuda:<version>` 镜像 | ~4 GiB | CUDA 12.1 runtime + Ubuntu 22.04 + 系统库 + 时区 + miniconda3 base（**无 envs**） |
| `bishon-cuda-image-<version>.tar` | ~4 GiB | `docker save` 产出的镜像 tar |
| `bishon-release-<version>.tar.gz` | ~5–7 GiB | `python-env/` + `bishon/` 源码 + `models/` + `scripts/` + `.env.example` |

**目录布局**（部署机）：

```
<host-dir>/                          ← 由 -v 挂载到容器 /opt/bishon-data
├── python-env/                      ← 从 WSL envs/bishon 拷贝（可被 publish 升级）
├── bishon/                          ← 应用源码（可被 publish 升级）
├── models/                          ← 模型权重（可被 publish 升级）
├── BISHON_DB/                       ← 运行时数据（永不被覆盖）
│   ├── metadata.db                  ← SQLite (WAL 模式)
│   ├── faiss/                       ← 向量索引
│   └── content/                     ← 上传的原始文件
├── logs/                            ← 运行时日志（永不被覆盖）
│   ├── debug_logs/
│   └── qa_logs/
├── scripts/                         ← install/publish/start/stop/uninstall
├── .env                             ← 用户配置（永不被覆盖）
├── .image-tag                       ← 已安装的镜像 tag
└── .accelerator                     ← cuda / ascend
```

容器入口（`docker/entrypoint.sh`）做三件事：
1. 校验 `<host-dir>` 关键内容存在；
2. 创建软链接 `/opt/miniconda3/envs/bishon → /opt/bishon-data/python-env`，让 env 里硬编码的绝对路径在容器内仍能解析；
3. `cd /opt/bishon-data/bishon && exec python -m uvicorn ...`。

**`.env` 路径桥接**：`bishon_kernel/configs/model_config.py:13` 通过 `load_dotenv(root_path/.env)` 加载配置，`root_path` 推导为容器内 `/opt/bishon-data/bishon/`。但 `.env` 放在更上层（`/opt/bishon-data/.env`），原因：`bishon/` 会被 publish 替换，`.env` 放其内部有覆盖风险。桥接方式：`start.sh` 用 `docker run --env-file <host-dir>/.env` 把变量注入容器进程环境；`load_dotenv` 找不到 `bishon/.env` 时静默返回，不覆盖已注入的环境变量（python-dotenv 默认行为）。

**BISHON_DB / logs 路径重定向**（关键）：`model_config.py` / `faiss_client.py` / `custom_log.py` 都通过 `root_path` 拼接路径，所以 SQLite 元数据 (`BISHON_DB/metadata.db`)、FAISS 索引 (`BISHON_DB/faiss/`)、上传内容 (`BISHON_DB/content/`)、日志 (`logs/{debug,qa}_logs/`) 默认都落在 `root_path/` 即源码目录里。如果不重定向，部署侧会出两个问题：

1. **publish 升级时数据被覆盖**：`upgrade.sh` 原子替换 `bishon/`，源码目录里的 BISHON_DB 会被一起抹掉。
2. **WSL 测试场景触发避坑指南 #2**：若宿主侧 `bishon/` 路径在 NTFS 上（如 `/mnt/i/...` 经 9p/drvfs），SQLite WAL 会因 mmap/shm 不支持而 I/O 错误。

`entrypoint.sh` 在启动 uvicorn 之前，对 `bishon/BISHON_DB` 与 `bishon/logs` 创建符号链接到 `/opt/bishon-data/BISHON_DB` 与 `/opt/bishon-data/logs`（与源码目录同级）。这样：

- 应用代码读 `root_path/BISHON_DB/metadata.db` → 实际落盘 `/opt/bishon-data/BISHON_DB/metadata.db`（持久化、publish-safe、ext4）；
- 第一次启动自动创建符号链接；**publish 升级会清掉 `bishon/` 内的符号链接，下次 start 由 entrypoint 重新创建**——这是预期行为，因为 `bishon/` 是可替换的源码层；
- 若源码目录里已存在非空的真实 BISHON_DB/logs（异常情况），entrypoint 拒绝启动并提示迁移，避免数据丢失。

## 前置条件

### 开发机（构建镜像 + 制作发布包）

- **WSL2 Ubuntu 22.04**（必须 22.04，与镜像 base 一致，否则 env 内 `.so` 文件 glibc 不匹配）。
- **conda 环境 `bishon`** 已创建并安装全部依赖（`pip install -r requirements.txt`）。
- **Docker Desktop with WSL2 integration** 或 **Docker Engine in WSL**，`docker` 命令在 WSL 内可用。
- 仓库已 clone，前端已构建并拷贝：
  ```bash
  cd front_end && npm ci && npm run build && cd ..
  cp -r front_end/dist bishon_kernel/bishon_server/
  ```
  （运行时挂载点为 `bishon_kernel/bishon_server/dist/bishon/`，不是 `front_end/dist/`。）
- 模型已下载到 `models/`（`Qwen3-Reranker-0.6B/` 与 `paddleocr_models/`）。

### 部署机（安装运行）

- **Linux x86_64**，内核版本与 Ubuntu 22.04 兼容即可。
- **Docker** + **NVIDIA Container Toolkit**（仅 CUDA 镜像需要；验证：`docker run --rm --gpus all nvidia/cuda:12.1.0-runtime-ubuntu22.04 nvidia-smi`）。
- **`curl`**（启动脚本的健康检查需要）。
- **ext4（或非 9p/drvfs）文件系统**挂载点 — 见 [避坑指南 #2](#避坑指南对照表)。
- **模型文件**（部署机不需要直接下载，但开发机制作发布包时需要）：
  - 在线获取：开发机跑 `bash scripts/common/download-models.sh`（默认从 `hf-mirror.com` 国内镜像）
  - 离线获取：用 `--offline <bishon-models-*.tar.gz>` 从已有 tarball 解压
  - 内网无外网：把 `models/` 整目录通过 scp / USB 拷过来即可（gitignored，不入库）

## 开发机：构建镜像

```bash
bash scripts/docker/build-image.sh --version 2.1.0
```

输出：本地镜像 `bishon-cuda:2.1.0`。本步骤联网（apt 安装系统库 + 下载 miniconda）。

**镜像层验证**（可选，建议第一次构建后跑）：

```bash
IMG=bishon-cuda:2.1.0
docker run --rm "$IMG" date                                   # 应为 CST
docker run --rm "$IMG" /opt/miniconda3/bin/conda --version    # conda 可用
docker run --rm "$IMG" ls /opt/miniconda3/envs                # 应为空
docker run --rm "$IMG" ls /etc/localtime                      # 应为软链接到 Asia/Shanghai
```

## 开发机：制作离线发布包

### 一次性：瘦身边 bishon conda env

首次制作发布包前建议瘦身，可减少 1–2 GiB 体积：

```bash
# 清缓存包
conda clean -afy
# 清 pip 缓存（缓存不在 env 内，但顺手做）
pip cache purge
# 查看历史 revisions，决定是否回滚某些实验性安装
conda list --revisions
```

如发现明确无用的实验包（例如安装时为调试 torch 版本而装的旧 wheel），用 `pip uninstall <pkg>` 移除。**移除前与项目维护者确认；移除后必须重新跑 `bash run_all_tests.sh` 全绿再打包**，避免误删依赖。

### 发布内容清单：`release/MANIFEST`

发布 tarball 里 `bishon/` 子目录的精确内容由仓库根的 [`release/MANIFEST`](../release/MANIFEST) 决定。该文件是纯文本，每行一个相对仓库根的路径，注释以 `#` 开头。这是显式 opt-in：**不在 MANIFEST 里的路径不会进入发布包**。

`make-release.sh` 对每个 manifest 条目应用通用排除（`__pycache__`、`*.pyc`、`node_modules`、`front_end/dist`、`.git` 等），不需要在 MANIFEST 里重复声明。注意 `bishon_kernel/bishon_server/dist/` 是**保留**的（运行时挂载需要），不受 `front_end/dist` 这条排除影响。

新增要发布的路径时：编辑 `release/MANIFEST` 加一行即可。`release/README.md` 有更详细的格式说明。

### 制作发布包

```bash
bash scripts/docker/make-release.sh --version 2.1.0
```

`make-release.sh` 内置前置校验，任一失败即退出，不会产出残缺包：

| 校验项 | 失败原因 |
|---|---|
| `bishon` conda env 存在 | WSL 中未创建 env |
| WSL Ubuntu = 22.04 | env `.so` 文件 glibc 不匹配 |
| 关键 Python 包可 import（fastapi/uvicorn/torch/faiss/paddle/transformers/langchain） | env 残缺 |
| `bishon_kernel/bishon_server/dist/bishon/index.html` 存在 | 前端未构建/未拷贝 |
| `bishon-cuda:<version>` 镜像存在 | 未跑 build-image.sh |

产物在 `dist/`：

```
dist/
├── bishon-release-2.1.0.tar.gz     # 发布包（含 python-env + 源码 + 模型 + 脚本）
└── bishon-cuda-image-2.1.0.tar     # docker save 产出的镜像 tar
```

把这两个文件复制到部署机（U 盘、内网 scp、共享盘均可）。

## 部署机：首次安装

```bash
bash install.sh \
    --host-dir /var/lib/bishon \
    --release /path/to/bishon-release-2.1.0.tar.gz \
    --image   /path/to/bishon-cuda-image-2.1.0.tar \
    --accelerator cuda
```

`install.sh` 干这些事：

1. **文件系统校验**（[避坑指南 #2](#避坑指南对照表)）：
   - 拒绝 `/mnt/*`、`/media/*`、`/run/media/*` 路径（覆盖 WSL drvfs 与 Linux 自动挂载，SQLite WAL 会 I/O 错误）；
   - 拒绝 `9p|drvfs|tmpfs|overlay|smbfs|cifs` 文件系统；
2. 创建目录骨架（`python-env/` `bishon/` `models/` `BISHON_DB/{faiss,content}` `logs/{debug_logs,qa_logs}`）；
3. `docker load` 镜像 tar；
4. 解压发布包，原子 mv 到 `<host-dir>/`；
5. 仅当 `.env` 不存在时拷贝 `.env.example` 为 `.env`（**永不被覆盖**）；
6. 写 `.image-tag` 与 `.accelerator`。

**安装后必做**：编辑 `<host-dir>/.env`，把 `OPENAI_API_BASE` 和 `EMBEDDING_API_BASE` 改为部署机上真实可达的 URL（[避坑指南 #1](#避坑指南对照表)：**不要用 `host.docker.internal`**，详见下方避坑表）。

## 部署机：启动与健康检查

```bash
bash /var/lib/bishon/scripts/docker/start.sh --host-dir /var/lib/bishon
```

`start.sh` 会：

1. 读取 `.image-tag` 决定镜像，读取 `.accelerator` 决定 GPU 标志；
2. `docker rm -f bishon`（清理同名旧容器）；
3. `docker run -d` 启动，挂载 `<host-dir>` + `--env-file <host-dir>/.env` + `--gpus all` + 端口 8777；
4. 轮询 `curl http://localhost:8777/api/health`，**最长等 180 秒**（冷启动需要加载 torch/paddle/transformers 与 Rerank/OCR 模型）；
5. 健康检查通过后，再 `curl /bishon/` 校验静态资源（[避坑指南 #4 陷阱 2](#避坑指南对照表)）。

启动成功的标志：日志末尾有 `Bishon is up (after Ns)` 与 `UI assets served at /bishon/ (200 OK)`。

服务地址：<http://localhost:8777/bishon/>

## 部署机：升级（publish）

代码或模型变更时，开发机重跑 `make-release.sh`（同版本号或递增均可，递增更清晰），把新 `bishon-release-<v>.tar.gz` 复制到部署机后：

```bash
bash /var/lib/bishon/scripts/upgrade.sh \
    --host-dir /var/lib/bishon \
    --release /path/to/bishon-release-2.1.1.tar.gz

bash /var/lib/bishon/scripts/docker/stop.sh  --host-dir /var/lib/bishon
bash /var/lib/bishon/scripts/docker/start.sh --host-dir /var/lib/bishon
```

`upgrade.sh` 原子替换 `bishon/`、`models/`（若新包内有 `python-env/` 也替换），**永远不动**：

- `.env`（用户配置）
- `BISHON_DB/`（运行时数据）
- `logs/`（运行时日志）
- `.image-tag`、`.accelerator`

如需升级 Python 依赖（新发布包含 `python-env/`），且镜像的 miniconda3 base 版本变了，**必须同时重新 build + load 镜像**。`install.sh` 不重新跑——它假设首次安装已完成；改用：

```bash
docker load -i /path/to/bishon-cuda-image-2.1.1.tar   # 加载新镜像
echo "bishon-cuda:2.1.1" > /var/lib/bishon/.image-tag  # 切换 tag
bash /var/lib/bishon/scripts/upgrade.sh --host-dir /var/lib/bishon --release bishon-release-2.1.1.tar.gz
bash /var/lib/bishon/scripts/docker/stop.sh  --host-dir /var/lib/bishon
bash /var/lib/bishon/scripts/docker/start.sh --host-dir /var/lib/bishon
```

## 部署机：卸载

```bash
# 不删数据：仅移除容器 + 镜像
bash /var/lib/bishon/scripts/uninstall.sh --host-dir /var/lib/bishon

# 完全清除：脚本拒绝自动 rm -rf，需要手动执行（防误删）
bash /var/lib/bishon/scripts/uninstall.sh --host-dir /var/lib/bishon --purge-data
# 然后人工:
rm -rf /var/lib/bishon
```

## 避坑指南对照表

对应 `F:\Note\Typora\系统\docker\Docker部署避坑指南.md` 的 5 类陷阱：

| # | 避坑指南条目 | 本设计对策 | 实现位置 |
|---|---|---|---|
| 1 | `host.docker.internal` 在嵌套虚拟化（VMware / WSL2 原生 Docker Engine）中只解析到 docker0 网桥，访问不到 Windows 主机 | 不依赖任何 host 别名。`.env` 中 `OPENAI_API_BASE` / `EMBEDDING_API_BASE` 由用户显式填部署机真实可达 URL（同机部署可填 `http://localhost:11434/v1` 或同网段 IP）。`install.sh` 末尾提示这一步。 | `.env.example`、`install.sh:Next steps` |
| 2 | WSL2 通过 9p 协议访问 NTFS，SQLite 的 WAL 模式（依赖 mmap / 共享内存）会触发 I/O 错误，容器无限重启 | `install.sh` 在 mkdir 后立即 `df -T` 校验，拒绝 `/mnt/*`、`/media/*`、`/run/media/*` 路径，并拒绝 `df -T` 报告为 `9p`/`drvfs`/`tmpfs`/`overlay`/`smbfs`/`cifs` 的文件系统（shell `case` 模式匹配）。引导用户用 ext4 路径（如 `~/bishon-data`、`/var/lib/bishon`）。 | `install.sh` 第 1 段文件系统校验 |
| 3 | 容器默认 UTC 时区，业务代码用本地时间生成查询参数会与 UTC+8 数据服务错位 8 小时 | 镜像内三件套：① `apt install tzdata`；② `ENV TZ=Asia/Shanghai`；③ `ln -snf /usr/share/zoneinfo/$TZ /etc/localtime`。`docker run --rm <image> date` 应显示 CST。 | `docker/Dockerfile.cuda` |
| 4 陷阱 1 | 发布流程把开发机的本地 `.env` 打入发布包，部署时覆盖目标环境已定制配置 | 发布包**不含 `.env`**（`make-release.sh` rsync 排除）。`install.sh` 仅当 `.env` 不存在时从 `.env.example` 创建；`upgrade.sh` **永远不动 `.env`**。 | `make-release.sh` rsync、`install.sh` step 5、`upgrade.sh` |
| 4 陷阱 2 | 发布包遗漏静态资源目录，启动时路由检测失败，访问返回 404 | ① `make-release.sh` 前置校验 `bishon_kernel/bishon_server/dist/bishon/index.html` 存在；② 安装时再校验；③ `start.sh` 启动后 `curl /bishon/` 验证 200。 | `make-release.sh` step 0c、`install.sh` step 4、`start.sh` step 5 |
| 5 | 部署后不校验，容器启动成功 ≠ 服务可用 | `start.sh` 内置：① `curl /api/health` 等待 180 秒（覆盖冷启动）；② `curl /bishon/` 校验静态资源；③ 失败时 `docker logs bishon | tail -50` 自动打印。 | `start.sh` step 4–5 |

## 常见排障

### 启动后 `/api/health` 始终返回不成功

按顺序检查：

```bash
docker logs bishon 2>&1 | tail -100
docker exec bishon ls /opt/bishon-data/bishon/bishon_kernel/bishon_server/dist/bishon/
docker exec bishon /opt/miniconda3/envs/bishon/bin/python -c "import torch; print(torch.cuda.is_available())"
docker exec bishon bash -lc 'echo LLM=$OPENAI_API_BASE; curl -sS -m 5 "$OPENAI_API_BASE/models" | head -c 200'
```

最后一条用单引号让 `$OPENAI_API_BASE` 在**容器内**展开。若返回空或错误，说明容器无法访问 LLM 服务 — 检查 [.env] 配置（[避坑指南 #1](#避坑指南对照表)）。

### 安装时报 "filesystem is 9p/drvfs"

把 `<host-dir>` 换成 WSL ext4 路径，例如 `~/bishon-data`（=`/home/<user>/bishon-data`）或 `/var/lib/bishon`。**不要**用 `/mnt/c/...` 之类 Windows 盘符。

### publish 后容器仍跑老代码

确认你跑了 `stop.sh && start.sh`（publish 不重启容器）。校验：

```bash
docker exec bishon sha256sum /opt/bishon-data/bishon/bishon_kernel/bishon_server/app.py
# 对照宿主侧:
sha256sum /var/lib/bishon/bishon/bishon_kernel/bishon_server/app.py
```

两个 hash 应该一致。

### 镜像构建慢 / 失败

`docker/Dockerfile.cuda` 中的 `wget miniconda` 这一步需要网络。如需完全离线构建：

1. 在开发机下载 `Miniconda3-latest-Linux-x86_64.sh` 放到 `docker/`；
2. Dockerfile 改 `wget` 行为 `COPY Miniconda3-latest-Linux-x86_64.sh /tmp/miniconda.sh`；
3. 重跑 `build-image.sh`。

（本项留作后续优化，本轮默认联网构建。）

## 不在本文档范围

- **Ascend（CANN）镜像**：`docker/Dockerfile.ascend` 为占位文件，本轮不实现。需要时按文件内 TODO 实现，并扩展 `start.sh` 的 `ascend` 分支。
- **docker-compose**：单容器 + 外部 LLM 的设计不需要 compose；如未来把 LLM 也容器化再加。
- **CI 自动构建镜像**：本轮人工构建；CI 集成留作后续。
- **Windows Docker Desktop 适配**：用户场景是 WSL/Linux；Windows Docker Desktop 不在主路径。
