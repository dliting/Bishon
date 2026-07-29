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

`shell-checks.sh` 要求 `bats` 在 PATH 上。CI 安装方式：

| 平台 | 安装命令 |
|---|---|
| GitHub Actions (ubuntu-latest) | `sudo apt-get update && sudo apt-get install -y bats` |
| GitLab CI (Debian/Ubuntu runner) | `apt-get update && apt-get install -y bats` |
| GitLab CI (Docker executor) | 预装到 base image |
| Gitea Actions | 同 GitHub Actions |
| Jenkins | 取决于 agent 类型 |
| macOS runner | `brew install bats-core` |
| 内网无外网 | **预装到 CI 基础镜像**（强烈推荐） |

> 内网部署尤其推荐"预装到基础镜像"——避免 CI 流水线在线 apt 安装受外网/镜像源影响。

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
