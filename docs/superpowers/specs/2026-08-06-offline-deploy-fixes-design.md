# Bishon V2 离线部署三问题修复设计

日期: 2026-08-06（更新: 2026-08-07）

## 问题背景

Bishon V2 离线部署到原生 Linux（非 WSL2）时，发现三个根本性问题需要从架构层面修复。

---

## 问题 1：tiktoken 离线缓存缺失

### 根因

tiktoken 首次使用 `cl100k_base` 编码时，需从 `openaipublic.blob.core.windows.net` 下载 ~1.6MB 的编码文件。离线环境无法下载，导致文件处理失败。

### 方案：将缓存文件打包进 models 目录，通过 `TIKTOKEN_CACHE_DIR` 自动指向

1. **make-release.sh**：在构建 models tarball 之前，预生成 tiktoken 缓存到 `models/tiktoken_cache/`
2. **entrypoint.sh**：`export TIKTOKEN_CACHE_DIR=$DATA_ROOT/models/tiktoken_cache`，并 `mkdir -p` 确保目录存在
3. **bare-metal/start.sh**：`export TIKTOKEN_CACHE_DIR="$SOURCE_DIR/models/tiktoken_cache"`

**为什么放 models/ 而不是 python-env/**：
- tiktoken 缓存本质上是模型数据，与 paddleocr_models、Reranker 同类
- models/ 是 install.sh 单独解压的，增减内容不影响 python-env 的构建和瘦身逻辑
- bare-metal 模式下 models/ 也在项目根目录下，路径一致

---

## 问题 2：models 路径不统一

### 根因

- install.sh 将 models 解压到 `$HOST_DIR/models/`
- Bishon 代码用 `root_path/models/`，Docker 内 `root_path` 是 `/opt/bishon-data/bishon/`，所以期望 `/opt/bishon-data/bishon/models/`
- 两套路径，导致 Docker 模式下找不到模型文件

### 方案：通过 `MODELS_DIR` 环境变量统一路径

**设计原则**：一个真相源——`model_config.py` 中的 `models_dir` 是唯一的 models 路径定义。

1. **model_config.py**：
   ```python
   models_dir = os.getenv("MODELS_DIR", os.path.join(root_path, "models"))
   ```
   - Docker 模式：entrypoint.sh 设置 `MODELS_DIR=/opt/bishon-data/models`
   - bare-metal 模式：start.sh 显式设置 `MODELS_DIR=$SOURCE_DIR/models`（与 Docker 对称）

2. **resolve_model_path()**：兼容旧 `.env` 格式（`./models/X`、`models/X`），自动去除 `models/` 前缀后拼接到 `models_dir`。使用显式前缀检查（非 `lstrip`），避免误删 dot-prefixed 模型名。

3. **所有消费者**从 `model_config` 导入 `models_dir`：
   - `local_doc_qa.py`：`os.path.join(models_dir, 'paddleocr_models')`
   - `rerank_client.py`：`resolve_model_path(RERANK_MODEL_PATH)`

4. **redirect_runtime_dirs.sh**：移除 `_redirect_one models`（不再用符号链接）

5. **.env.example**：`RERANK_MODEL_PATH=Qwen3-Reranker-0.6B`（新格式，无 `models/` 前缀）

**为什么用环境变量而不是符号链接**：
- 环境变量是显式配置，语义清晰
- 符号链接是隐式桥接，用户不知道 `bishon/models` 实际指向哪里
- 两种模式（Docker/bare-metal）用同一机制，不需要两套逻辑

---

## 问题 3：Docker 模式下服务地址配置

### 根因

`.env` 中 `OPENAI_API_BASE` 等服务地址配 `localhost`，容器内 `localhost` 指向容器自身，不是宿主机。

### 方案：用户在 `.env` 中配置实际可达的地址

**设计原则**：网络配置应由用户明确指定，启动脚本不应静默覆盖。

1. **start.sh**：移除服务地址自动覆盖逻辑（`_rewrite_if_local`、`HOST_ADDR_OVERRIDE`、`--add-host host.docker.internal`）
2. **.env.example**：注释说明 Docker 模式应配实际 IP，不是 localhost
3. **实际部署**：vLLM 服务在 192.168.10.101，`.env` 配 `http://192.168.10.101:8000/v1`，Docker 和 bare-metal 都通

**为什么去掉自动覆盖**：
- 自动覆盖本质上是猜测用户意图——假设 docker0 网桥 IP、假设 localhost 需要替换
- 静默改了配置，用户不知道实际用了什么地址
- 用户配了明确 IP（如 192.168.10.101）后，Docker 和 bare-metal 都能通，不需要特殊处理

---

## upgrade.sh overlay 方式

### 问题

旧版 upgrade.sh 用 `mv` swap 方式替换目录，存在两个问题：
1. `mv` 移走 bishon/ 后，其中的运行时数据（BISHON_DB 符号链接、logs 符号链接、__pycache__）会丢失
2. `rm -rf` 清理备份时遇到 root-owned `__pycache__` 文件会因权限不足失败，`set -e` 导致脚本退出

### 方案：overlay（目录合并）方式

1. **备份**：`cp -a "$cur" "$old"`（完整复制，保留所有运行时数据）
2. **覆盖**：`cp -a "$new/." "$cur/"`（新文件覆盖旧文件，不在 tarball 中的文件保留）
3. **清理**：best-effort 删除备份，失败则报告 `sudo rm -rf` 命令

**为什么 node-env 用 swap（mv）而非 overlay**：
- node-env 没有运行时数据需要保留
- mv 更简洁，O(1) 磁盘消耗

### 其他改进

- **磁盘空间预检**：upgrade.sh 开始前检查可用空间，至少 5 GB
- **日志标签**：`BISHON_LOG_TAG=upgrade`（不再是 `publish`）
- **src-only 包不创建 python-env 占位目录**：make-release.sh `--skip-env` 模式不再创建空的 `python-env/` + `.skip-env` 哨兵，upgrade.sh 的 `[ -d "$new" ] || return 0` 自然跳过
- **install.sh 拒绝 src-only 包**：移除 `.skip-env` 哨兵检查，首次安装必须用完整包

---

## 验证

1. **tiktoken**：全新离线部署后，上传文件不再报下载失败
2. **models 路径**：全新离线部署后，`/api/health` 中 OCR 服务 healthy（无需手动符号链接）
3. **服务地址**：`.env` 配置实际 IP 后，`/api/health` 中 LLM 和 Embedding healthy
4. **单元测试**：268 个通过，新增 `test_model_config.py` 9 个测试
5. **增量部署**：`make-release.sh --skip-env --skip-models --skip-image --skip-node` + `upgrade.sh` + 重启容器，全流程验证通过
6. **目标机器验证**：192.168.10.101 上 upgrade 后 `/api/health` 返回 `"status": "ok"`，所有服务 healthy
