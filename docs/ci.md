# Bishon V2 CI 设计

本文档说明 Bishon V2 CI 的设计原则，便于未来迁移到内部 Git 服务（GitLab CI / Gitea Actions / Jenkins / 自研）。

## 核心原则：解耦

**所有 shell 端测试逻辑封装在 `scripts/ci/shell-checks.sh`，CI 平台 YAML 只调用这个脚本。**

```yaml
# GitHub Actions
- run: bash scripts/ci/shell-checks.sh

# GitLab CI
script: bash scripts/ci/shell-checks.sh

# Jenkins Pipeline (Jenkinsfile)
sh 'bash scripts/ci/shell-checks.sh'

# Gitea Actions
- run: bash scripts/ci/shell-checks.sh
```

迁移到任何 CI 平台只需要复制粘贴这一行 + 配好 runner。

## `scripts/ci/shell-checks.sh` 做什么

按顺序跑三个检查：

1. **bash -n 语法检查**：`docker/` 和 `scripts/docker/` 下所有 `.sh` 文件。
2. **release/MANIFEST 校验**：调用 `scripts/docker/validate-manifest.sh`，确保 manifest 列的每条路径都存在于仓库。
3. **bats 测试**：`tests/scripts/*.bats` 全部用例。

退出码 0 = 全过，非 0 = 有失败。

## bats 依赖的处理

`shell-checks.sh` 要求 `bats` 在 PATH 上。**不要在 YAML 里 inline 写 `apt install bats`**——这绑定 GitHub Actions 假设且在内网 CI 会失败。

### 推荐：`scripts/ci/install-bats.sh`

封装好的多平台安装脚本，按顺序尝试：

1. bats 已在 PATH → 跳过
2. `apt-get install bats`（有 sudo 或 root）
3. `brew install bats-core`（macOS）
4. 从 GitHub 下载源码 tarball 装到 `~/.local`（最后兜底）

CI YAML 只调一行：

```yaml
- run: bash scripts/ci/install-bats.sh
- run: bash scripts/ci/shell-checks.sh
```

### 内网无外网：预装到 CI 基础镜像

设 `BISHON_CI_BATS_PREINSTALLED=1` 环境变量。`install-bats.sh` 在该模式下：
- 如果 bats 已在 PATH → 跳过（正常）
- 如果 bats 不在 PATH → **大声失败**（防止 silent skip 让 CI 假绿）

CI 基础镜像里预装的常见方式：

| 基础镜像 | 预装命令 |
|---|---|
| Debian/Ubuntu | `apt-get install -y bats` |
| Alpine | `apk add --no-cache bats` |
| CentOS/RHEL | `yum install -y bats` (EPEL) 或从源码 |
| 自研镜像 | Dockerfile 里 `RUN <install>` |

### 完整调用示例（GitHub Actions）

```yaml
shell:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - run: bash scripts/ci/install-bats.sh
    - run: bash scripts/ci/shell-checks.sh
```

### 完整调用示例（内网 GitLab CI，预装 bats）

```yaml
# .gitlab-ci.yml
shell:
  image: internal-registry/bishon-ci-runner:latest  # 已预装 bats
  variables:
    BISHON_CI_BATS_PREINSTALLED: "1"
  script:
    - bash scripts/ci/shell-checks.sh
```

## 本地开发

```bash
# CI 模式（要求 bats 在 PATH，等同 CI 行为）
bash scripts/ci/shell-checks.sh

# 开发模式（bats 缺失时跳过 bats，给出警告）
bash scripts/ci/shell-checks.sh --local
```

bats 安装：
```bash
# WSL Ubuntu
sudo apt install bats

# macOS
brew install bats-core

# 从源码（无包管理器时）
git clone https://github.com/bats-core/bats-core.git /tmp/bats
/tmp/bats/install.sh ~/.local
export PATH="$HOME/.local/bin:$PATH"
```

## 当前 `.github/workflows/ci.yml`

| Job | 内容 |
|---|---|
| `backend` | Python 3.11 + 3.12，pip install + ruff + pytest tests/backend/unit |
| `frontend` | Node 20，npm ci + vitest + npm build |
| `shell` | Checkout + 装 bats + 调 `scripts/ci/shell-checks.sh` |

`shell` job 只做平台调度，业务逻辑全在 `scripts/ci/shell-checks.sh`。

## 迁移清单

把 Bishon CI 迁到非 GitHub Actions 平台时：

1. **保留不动**：
   - `scripts/ci/shell-checks.sh`
   - `scripts/docker/validate-manifest.sh`
   - `tests/scripts/*.bats`
   - 所有 shell 端测试逻辑

2. **重写**（平台调度层）：
   - 检出代码语法（`uses: actions/checkout@v4` → GitLab 内置 / Jenkins `checkout` 步骤）
   - runner 标签（`runs-on: ubuntu-latest` → GitLab `tags:` / Jenkins `agent label`）
   - step / job 定义语法

3. **环境前置**（重要）：
   - 在 CI 镜像里预装 `bats`（避免内网无 apt 源问题）
   - 如走 Docker executor，构建一个含 bats 的 base image

4. **测试调用**：每个 job 一行 `bash scripts/ci/shell-checks.sh`。
