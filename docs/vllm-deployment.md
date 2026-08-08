# Bishon V2 离线部署指南

本文档记录 Bishon V2（含 vLLM 推理服务）的离线部署流程，包括踩坑记录和注意事项。

## 架构概览

| 服务 | 模型 | 端口 | API 路径 | 用途 |
|------|------|------|----------|------|
| Bishon | — | 8777 | `/api/health` | 文档问答系统（Docker 容器） |
| LLM | Qwen3.5-4B-AWQ-4bit | 8000 | `/v1/chat/completions` | 对话推理，支持思维链 |
| Embedding | Qwen3-Embedding-0.6B | 8001 | `/v1/embeddings` | 文本向量化 |

vLLM 服务独立运行于宿主机，Bishon 运行于 Docker 容器内，通过 Docker 网桥通信。

## 环境要求

| 项目 | 要求 |
|------|------|
| OS | Ubuntu 22.04 LTS (x86_64) |
| GPU | NVIDIA GPU，显存 ≥ 6GB（4B 模型约 3GB，Embedding 约 0.5GB） |
| NVIDIA 驱动 | ≥ 535（支持 CUDA 12.6） |
| conda | miniconda3 或 anaconda3 |
| 磁盘 | 模型 ~5GB + conda 环境 ~10GB（压缩包 ~4.6GB） |

## 离线部署步骤

### 1. 准备阶段（在有网络的机器上）

#### 1.1 打包 conda 环境

```bash
# 打包 vllm_serve 环境（约 10G，压缩后约 4.6G，耗时约 7 分钟）
tar czf vllm_serve_env.tar.gz -C /opt/miniconda3/envs vllm_serve
```

**注意**：必须打包整个 conda 环境，不能只装 vllm 包。原因：
- vllm 依赖特定版本的 torch + CUDA runtime，版本不匹配会导致运行时错误
- 不同 vllm 版本 CLI 参数不同（0.6.x vs 0.18.x vs 0.19.x），脚本与版本强绑定
- conda 环境内含编译好的 CUDA kernel，与 GPU 架构相关

#### 1.2 准备模型文件

```bash
# 模型目录结构
/opt/models/
├── Qwen3.5-4B-AWQ-4bit/    # ~3.8GB
│   ├── config.json
│   ├── model-*.safetensors
│   └── ...
└── Qwen3-Embedding-0.6B/   # ~1.2GB
    ├── config.json
    ├── model.safetensors
    └── ...
```

#### 1.3 准备启停脚本

脚本位于 `/opt/scripts/`：

| 脚本 | 功能 |
|------|------|
| `start-qwen3.5-4b.sh` | 启动 LLM 服务（端口 8000） |
| `stop-qwen3.5-4b.sh` | 停止 LLM 服务 |
| `start-embedding.sh` | 启动 Embedding 服务（端口 8001） |
| `stop-embedding.sh` | 停止 Embedding 服务 |

脚本关键配置：
- `CONDA_ENV=vllm_serve` — conda 环境名
- `MODEL_PATH` — 模型路径
- `PORT` — 服务端口
- `--reasoning-parser qwen3` — 支持 Qwen3.5 思维链（需 vllm ≥ 0.18.0）
- `--speculative-config` — 投机解码加速（需 vllm ≥ 0.18.0）
- `--language-model-only` — VLM 仅启用文本部分
- `--convert embed` — Embedding 模式

### 2. 传输阶段

```bash
# 传输 conda 环境压缩包
scp vllm_serve_env.tar.gz ubuntu@<target>:/opt/bishon-home/

# 传输启停脚本
scp start-qwen3.5-4b.sh stop-qwen3.5-4b.sh \
    start-embedding.sh stop-embedding.sh \
    ubuntu@<target>:/opt/scripts/

# 传输模型文件（如果目标机器没有）
scp -r /opt/models/Qwen3.5-4B-AWQ-4bit ubuntu@<target>:/opt/models/
scp -r /opt/models/Qwen3-Embedding-0.6B ubuntu@<target>:/opt/models/
```

### 3. 安装阶段（在目标机器上）

```bash
# 解压 conda 环境到 miniconda3/envs/
tar xzf /opt/bishon-home/vllm_serve_env.tar.gz -C /opt/miniconda3/envs/

# 验证环境可用
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate vllm_serve
python -c "import vllm; print(vllm.__version__)"  # 应输出 0.18.0

# 清理压缩包
rm -f /opt/bishon-home/vllm_serve_env.tar.gz
```

### 4. 启动与验证

```bash
# 启动 Embedding 服务（先启动，占用显存少）
bash /opt/scripts/start-embedding.sh

# 启动 LLM 服务
bash /opt/scripts/start-qwen3.5-4b.sh

# 验证 LLM
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3.5-4B","messages":[{"role":"user","content":"你好"}],"max_tokens":50}'

# 验证 Embedding
curl http://localhost:8001/v1/models
curl http://localhost:8001/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3-Embedding-0.6B","input":"测试文本"}'
```

## 踩坑记录

### 1. WSL2 NAT 网络限制

**现象**：WSL2 内无法 `ssh`/`ping` 局域网 IP（如 192.168.10.101），但 Windows 宿主机可以。

**原因**：WSL2 使用虚拟网卡（NAT 模式），与宿主机不在同一网段，无法直接路由到局域网。

**解决方案**：
- 方案 A：通过 Windows PowerShell 转发
  ```bash
  powershell.exe -Command "ssh ubuntu@192.168.10.101 'command'"
  powershell.exe -Command "scp file ubuntu@192.168.10.101:/path/"
  ```
- 方案 B：安装 `sshpass` 实现密码自动输入（WSL2 网络恢复后可用）
  ```bash
  sudo apt install sshpass
  sshpass -p 'password' ssh ubuntu@192.168.10.101 'command'
  ```
- 方案 C：配置 WSL2 镜像网络模式（Windows 11 22H2+），在 `%USERPROFILE%\.wslconfig` 中设置：
  ```ini
  [wsl2]
  networkingMode=mirrored
  ```

### 2. v9fs 文件系统限制

**现象**：在 Windows 驱动器挂载点（如 `/mnt/c/`、`/opt/Bishon/release/` → Windows I: 盘符号链接）上执行 `rsync`、`tar` 大文件操作时报错（mkstemp failed、Permission denied）。

**原因**：WSL2 通过 v9fs 协议访问 Windows 文件系统，不支持部分 Linux 文件操作（如原子创建临时文件）。

**解决方案**：在 ext4 文件系统（WSL2 本地路径）上执行大文件操作，完成后复制到 Windows 挂载点。

### 3. conda 环境名不匹配

**现象**：目标机器已有 `vllm`（0.6.3）和 `vllm2`（0.19.0）环境，但脚本使用 `vllm_serve`（0.18.0），环境名不一致。

**原因**：不同机器上 conda 环境命名不统一。

**解决方案**：打包整个 `vllm_serve` 环境传输，保持环境名一致。这比修改脚本适配目标环境更可靠，因为：
- 避免了 vllm 版本差异导致的参数不兼容
- 避免了 torch/CUDA 版本不匹配导致的运行时错误

### 4. vllm 版本差异

**现象**：不同 vllm 版本 CLI 参数差异大：
- 0.6.x：不支持 `--reasoning-parser`、`--speculative-config`、`--convert embed`
- 0.18.x：支持上述所有参数
- 0.19.x：参数略有变化

**解决方案**：打包整个 conda 环境，确保 vllm 版本与脚本参数一致。

### 5. 端口冲突

**现象**：目标机器已有 Qwen3.5-9B 服务占用端口 8000。

**解决方案**：先停掉 9B 服务再部署，或修改脚本使用不同端口。脚本中 `PORT` 变量可灵活调整。

### 6. NVIDIA 驱动版本不匹配

**现象**：`nvidia-smi` 显示 kernel module 与 userspace 版本不一致（如 580.95 vs 580.173），导致 CUDA 初始化失败。

**解决方案**：重启机器使驱动版本一致。如果重启后仍不匹配，需重新安装 NVIDIA 驱动。

## GPU 显存规划

| 模型 | 显存占用 | gpu-memory-utilization | 说明 |
|------|----------|----------------------|------|
| Qwen3.5-4B-AWQ-4bit | ~3.5GB | 0.6 | AWQ 4bit 量化，单卡即可 |
| Qwen3-Embedding-0.6B | ~0.5GB | 0.25 | 小模型，显存占用极低 |

双 RTX 4090 (48GB) 上两个服务可轻松共存。如果同时运行 Qwen3.5-9B（需 ~18GB），则需调整 `gpu-memory-utilization` 或使用 `CUDA_VISIBLE_DEVICES` 隔离 GPU。

## Bishon 配置对接

在 Bishon 的 `.env` 中配置：

```bash
# LLM
OPENAI_API_BASE=http://localhost:8000/v1
OPENAI_API_MODEL_NAME=Qwen3.5-4B
OPENAI_API_KEY=EMPTY

# Embedding
EMBEDDING_API_BASE=http://localhost:8001/v1/embeddings
EMBEDDING_MODEL_NAME=Qwen3-Embedding-0.6B
EMBEDDING_API_KEY=EMPTY
```

如果 Bishon 与 vLLM 不在同一台机器，将 `localhost` 替换为 vLLM 服务所在机器的 IP。

---

## Bishon Docker 离线部署

### 1. 准备 release 包

release 包由 `make-release.sh` 生成，包含：

| 文件 | 大小 | 说明 |
|------|------|------|
| `bishon-cuda-image-2.2.0.tar` | ~3.1G | Docker 镜像 |
| `bishon-release-2.2.0.tar.gz` | ~2M | Bishon 源码 + 前端 + 部署脚本（不含 python-env） |
| `bishon-pyenv-2.2.0.tar.gz` | ~7G | Python conda 运行环境（首次安装必需） |
| `bishon-models-2.2.0.tar.gz` | ~1.0G | Reranker + OCR 模型权重 |
| `bishon-node-2.2.0.tar.gz` | ~161M | Node.js 前端依赖（可选） |
| `deploy.sh` | — | 部署入口脚本 |

### 2. 传输到目标机器

```bash
scp -r release-2.2.0/ ubuntu@<target>:/opt/bishon-home/
```

### 3. 校验文件完整性

```bash
cd /opt/bishon-home/release-2.2.0/
for f in *.sha256; do sha256sum -c "$f"; done
```

### 4. 执行离线部署

```bash
bash deploy.sh --non-interactive \
  --mode docker-offline \
  --host-dir /opt/bishon-home \
  --release bishon-release-2.2.0.tar.gz \
  --pyenv bishon-pyenv-2.2.0.tar.gz \
  --image bishon-cuda-image-2.2.0.tar \
  --models bishon-models-2.2.0.tar.gz \
  --no-start
```

### 5. 配置 .env

```bash
# Docker 模式下，vLLM 在宿主机，需用 Docker 网桥 IP
# 查询网桥 IP：ip -4 addr show docker0 | grep inet
# 通常是 172.17.0.1

vi /opt/bishon-home/.env
```

关键配置：
```bash
OPENAI_API_BASE=http://172.17.0.1:8000/v1
EMBEDDING_API_BASE=http://172.17.0.1:8001/v1/embeddings

# tiktoken 离线缓存（entrypoint.sh 自动设置，无需手动配置）
# TIKTOKEN_CACHE_DIR=/opt/bishon-home/models/tiktoken_cache
```

### 6. tiktoken 离线缓存（已内置）

`make-release.sh` 自动将 tiktoken 缓存预生成到 `models/tiktoken_cache/` 并打包进 release。`entrypoint.sh` 和 bare-metal `start.sh` 自动设置 `TIKTOKEN_CACHE_DIR`，无需手动配置。

如需手动生成缓存（例如更新 tiktoken 版本后）：

```bash
# 生成缓存（在有网络的机器上）
TIKTOKEN_CACHE_DIR=/path/to/tiktoken_cache python3 -c "
import os; os.environ['TIKTOKEN_CACHE_DIR']='/path/to/tiktoken_cache'
os.makedirs('/path/to/tiktoken_cache', exist_ok=True)
import tiktoken; tiktoken.get_encoding('cl100k_base')
"

# 传输到目标机器
scp -r tiktoken_cache/ ubuntu@<target>:/opt/bishon-home/tiktoken_cache/
```

### 7. 模型路径（无需手动配置）

`entrypoint.sh` 自动设置 `MODELS_DIR=/opt/bishon-home/models`，Bishon 代码通过此环境变量定位模型文件。无需手动创建符号链接。

### 8. 注册 NVIDIA Container Toolkit

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
# 验证
docker info | grep -i runtime
```

### 9. 启动 Bishon

```bash
# vLLM 与 Bishon 同机时推荐 --network host，.env 中可用 localhost
bash /opt/bishon-home/scripts/docker/start.sh --host-dir /opt/bishon-home --network host
```

### 10. 验证

```bash
# 健康检查
curl http://localhost:8777/api/health

# 前端访问
# 浏览器打开 http://<target-ip>:8777/bishon/
```

---

## 踩坑记录

### 1. WSL2 NAT 网络限制

**现象**：WSL2 内无法 `ssh`/`ping` 局域网 IP，但 Windows 宿主机可以。

**原因**：WSL2 使用虚拟网卡（NAT 模式），与宿主机不在同一网段。

**解决方案**：
- 方案 A：通过 Windows PowerShell 转发 `powershell.exe -Command "ssh ..."`
- 方案 B：安装 `sshpass`（`sudo apt install sshpass`）
- 方案 C：配置 WSL2 镜像网络模式（`.wslconfig` 中 `networkingMode=mirrored`）

### 2. v9fs 文件系统限制

**现象**：Windows 驱动器挂载点上 `rsync`/`tar` 大文件操作报错。

**解决方案**：在 ext4 文件系统上执行大文件操作。

### 3. conda 环境名不匹配 / vllm 版本差异

**现象**：目标机器已有 `vllm`（0.6.3）和 `vllm2`（0.19.0），脚本用 `vllm_serve`（0.18.0）。

**解决方案**：打包整个 conda 环境传输，保持环境名和版本一致。不同 vllm 版本 CLI 参数差异大（0.6.x 不支持 `--reasoning-parser`、`--speculative-config`、`--convert embed`）。

### 4. 端口冲突

**现象**：目标机器已有 Qwen3.5-9B 占用端口 8000。

**解决方案**：先停掉 9B 服务，或修改脚本 `PORT` 变量。

### 5. NVIDIA 驱动版本不匹配

**现象**：kernel module 与 userspace 版本不一致，CUDA 初始化失败。

**解决方案**：重启机器。如仍不匹配，重新安装 NVIDIA 驱动。

### 6. 容器内无法访问宿主机 LLM 服务

**现象**：Bishon Docker 容器内无法连接宿主机上的 LLM/Embedding 服务，报 "Connection refused"。

**原因**：Docker bridge 模式下，容器有独立网络命名空间，`localhost` 指向容器自身而非宿主机。

**解决方案**（三选一）：

1. **`--network host`**（推荐，LLM 与 Bishon 同机时）：容器共享宿主网络栈，`.env` 中直接用 `localhost`。
   ```bash
   bash start.sh --host-dir /opt/bishon-home --network host
   ```
   ```bash
   OPENAI_API_BASE=http://localhost:8000/v1
   EMBEDDING_API_BASE=http://localhost:8001/v1/embeddings
   ```

2. **Docker 网桥 IP**（bridge 模式）：在 `.env` 中使用网桥 IP（通常是 `172.17.0.1`）。
   ```bash
   ip -4 addr show docker0 | grep inet   # 查询网桥 IP
   OPENAI_API_BASE=http://172.17.0.1:8000/v1
   EMBEDDING_API_BASE=http://172.17.0.1:8001/v1/embeddings
   ```

3. **远程服务**：使用 LLM 服务所在机器的实际 IP。

### 7. tiktoken 离线缓存缺失

**现象**：容器启动后文件处理失败，日志报 `HTTPSConnectionPool(host='openaipublic.blob.core.windows.net'): Failed to resolve`。

**原因**：tiktoken 首次使用时需从互联网下载 `cl100k_base.tiktoken` 编码文件（~1.6MB），离线环境无法下载。

**解决方案**（已内置）：
1. `make-release.sh` 自动将 tiktoken 缓存预生成到 `models/tiktoken_cache/` 并打包进 release
2. `entrypoint.sh` 自动设置 `TIKTOKEN_CACHE_DIR=/opt/bishon-home/models/tiktoken_cache`
3. bare-metal `start.sh` 自动设置 `TIKTOKEN_CACHE_DIR=<source_dir>/models/tiktoken_cache`
4. 无需手动配置

### 8. PaddleOCR 模型路径不匹配

**现象**：OCR 服务 unhealthy，日志报 "PaddleOCR model dirs missing or empty"。

**原因**：install.sh 将 models 解压到 `$HOST_DIR/models/`，但 Bishon 代码期望在 `$HOST_DIR/bishon/models/`。

**解决方案**（已内置）：
1. `entrypoint.sh` 设置 `MODELS_DIR=/opt/bishon-home/models`
2. `model_config.py` 通过 `MODELS_DIR` 环境变量定位模型目录
3. bare-metal 模式默认使用 `root_path/models/`
4. 无需手动创建符号链接

### 9. NVIDIA Container Toolkit 未注册

**现象**：start.sh 报 "NVIDIA Container Toolkit not registered with Docker"。

**原因**：nvidia-container-toolkit 已安装但未注册到 Docker daemon。

**解决方案**：
```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 10. 前端 API_HOST 硬编码 localhost

**现象**：远程浏览器访问 Bishon 时，API 请求发到 `localhost:8777`（浏览器本机），而非目标机器。

**原因**：`front_end/.env.production` 中 `VITE_APP_API_HOST=http://localhost:8777` 在构建时写死到 JS 中。

**解决方案**：将 `VITE_APP_API_HOST` 设为空字符串，前端使用相对路径，浏览器自动使用当前页面的 host：
```
VITE_APP_API_HOST=
```

**注意**：修改后需重新构建前端（`npm run build`），清除 Vite 缓存（`rm -rf node_modules/.vite`），并更新 dist 目录。