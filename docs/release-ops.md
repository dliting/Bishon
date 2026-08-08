# Bishon V2 发布包操作规范

本文档规范发布包的制作、传输、保留和部署操作流程。

## 目录结构

### 开发机（制作端）

```
dist/
└── release-<ver>/
    ├── bishon-release-<ver>.tar.gz       # 源码 + 脚本 (~2 MB)
    ├── bishon-release-<ver>.tar.gz.sha256
    ├── bishon-pyenv-<ver>.tar.gz         # Python conda 环境 (~7 GB)
    ├── bishon-pyenv-<ver>.tar.gz.sha256
    ├── bishon-models-<ver>.tar.gz        # 模型权重 (~1 GB)
    ├── bishon-models-<ver>.tar.gz.sha256
    ├── bishon-node-<ver>.tar.gz          # Node.js + 前端依赖 (~160 MB, 可选)
    ├── bishon-node-<ver>.tar.gz.sha256
    ├── bishon-cuda-image-<ver>.tar       # Docker 镜像 (~4 GB)
    ├── deploy.sh                         # 部署入口
    ├── VERSION                           # 版本号
    └── README.md                         # 文件清单 + 快速指引
```

**保留策略**：`dist/release-<ver>/` 按版本号隔离，`make-release.sh` 不会删除旧版本。开发机保留最新完整发布包，以便随时 scp 到其他机器离线部署。**不要手动清理 `dist/` 目录**，除非磁盘空间紧张且确认旧版本不再需要。

### 目标机器（部署端）

```
/opt/bishon-release/
├── 2.2.0/                               ← 旧版本保留
│   ├── bishon-release-2.2.0.tar.gz
│   ├── bishon-pyenv-2.2.0.tar.gz
│   ├── bishon-models-2.2.0.tar.gz
│   └── ...
└── 2.2.1/                               ← 新版本
    ├── bishon-release-2.2.1.tar.gz
    └── ...
```

**保留策略**：按版本号子目录组织，不覆盖旧版本。旧版本可用于回滚。

## 制作发布包

```bash
# 完整发布（首次或 Python 依赖变更时）
bash scripts/docker/make-release.sh

# 仅源码更新（代码/前端变更，Python 依赖不变）
bash scripts/docker/make-release.sh --skip-pyenv --skip-models --skip-image

# 仅 Python 依赖更新
bash scripts/docker/make-release.sh --skip-models --skip-image
```

产出在 `dist/release-<ver>/`，按 `VERSION` 文件中的版本号命名。

## 传输到目标机器

```bash
# 传输整个版本目录（首次部署）
scp -r dist/release-<ver>/ ubuntu@<target>:/opt/bishon-release/<ver>/

# 仅传输源码包（增量升级，Python 依赖不变）
scp dist/release-<ver>/bishon-release-<ver>.tar.gz \
    ubuntu@<target>:/opt/bishon-release/<ver>/

# 传输源码 + pyenv（Python 依赖变更）
scp dist/release-<ver>/bishon-release-<ver>.tar.gz \
    dist/release-<ver>/bishon-pyenv-<ver>.tar.gz \
    ubuntu@<target>:/opt/bishon-release/<ver>/
```

**禁止覆盖已有发布包**：目标机器上 `/opt/bishon-release/<ver>/` 如果已存在，不要用 `scp` 直接覆盖。应使用新版本号子目录。

## 部署操作

### 首次安装

```bash
cd /opt/bishon-release/<ver>/
bash deploy.sh --non-interactive \
  --mode docker-offline \
  --host-dir /opt/bishon-home \
  --release bishon-release-<ver>.tar.gz \
  --pyenv bishon-pyenv-<ver>.tar.gz \
  --image bishon-cuda-image-<ver>.tar \
  --models bishon-models-<ver>.tar.gz
```

### 增量升级（仅代码变更）

```bash
bash /opt/bishon-home/scripts/docker/upgrade.sh \
  --host-dir /opt/bishon-home \
  --release /opt/bishon-release/<new-ver>/bishon-release-<new-ver>.tar.gz

bash /opt/bishon-home/scripts/docker/stop.sh --host-dir /opt/bishon-home
bash /opt/bishon-home/scripts/docker/start.sh --host-dir /opt/bishon-home
```

### 增量升级（Python 依赖变更）

```bash
bash /opt/bishon-home/scripts/docker/upgrade.sh \
  --host-dir /opt/bishon-home \
  --release /opt/bishon-release/<new-ver>/bishon-release-<new-ver>.tar.gz \
  --pyenv /opt/bishon-release/<new-ver>/bishon-pyenv-<new-ver>.tar.gz

bash /opt/bishon-home/scripts/docker/stop.sh --host-dir /opt/bishon-home
bash /opt/bishon-home/scripts/docker/start.sh --host-dir /opt/bishon-home
```

### 升级 Node 工具链

```bash
bash /opt/bishon-home/scripts/docker/upgrade.sh \
  --host-dir /opt/bishon-home \
  --release /opt/bishon-release/<new-ver>/bishon-release-<new-ver>.tar.gz \
  --node /opt/bishon-release/<new-ver>/bishon-node-<new-ver>.tar.gz
```

## 回滚

如果新版本有问题，可从旧版本目录重新安装：

```bash
# 停止当前容器
bash /opt/bishon-home/scripts/docker/stop.sh --host-dir /opt/bishon-home

# 用旧版本重新 upgrade（overlay 方式，保留 .env 和 BISHON_DB）
bash /opt/bishon-home/scripts/docker/upgrade.sh \
  --host-dir /opt/bishon-home \
  --release /opt/bishon-release/<old-ver>/bishon-release-<old-ver>.tar.gz \
  --pyenv /opt/bishon-release/<old-ver>/bishon-pyenv-<old-ver>.tar.gz

bash /opt/bishon-home/scripts/docker/start.sh --host-dir /opt/bishon-home
```

## 校验文件完整性

```bash
cd /opt/bishon-release/<ver>/
for f in *.sha256; do sha256sum -c "$f"; done
```
