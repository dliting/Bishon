# deploy.sh 向导重构 + 脚本目录重组 + 文档完善

## 背景

Bishon V2 的部署脚本经历了多轮迭代，积累了命名混淆、目录结构不对称、交互流程不直观等问题。本次重构解决 4 个用户痛点：

1. deploy.sh 向导不够直观——新手不知道有几步、每步问什么
2. Docker 和 bare-metal 的 start.sh/stop.sh 容易混淆
3. 缺少面向新手的"各部署方式怎么部署/启动/停止/卸载"快速参考
4. 启动成功后不提示日志在哪里看

不向下兼容——breaking change，旧部署需重新 install。

## 设计

### 1. 脚本目录重组

```
scripts/
├── common/                        ← 跨模式共享
│   ├── utils.sh                   ← 共享函数（原 lib/common.sh）
│   ├── wizard.sh                  ← 交互向导（新，4 步提问）
│   ├── download-models.sh         ← 模型下载
│   ├── preflight.sh               ← 发布前自检
│   └── validate-manifest.sh       ← MANIFEST 校验
├── docker/                        ← Docker 专属
│   ├── install.sh                 ← 首次安装
│   ├── start.sh                   ← 启动容器
│   ├── stop.sh                    ← 停止容器
│   ├── upgrade.sh                 ← 升级部署（原 publish.sh）
│   ├── uninstall.sh               ← 卸载
│   ├── build-image.sh             ← 构建镜像（原 build.sh）
│   ├── make-release.sh            ← 打包发布包
│   └── publish-image.sh           ← 推镜像到 registry
├── bare-metal/                    ← Bare-metal 专属
│   ├── start.sh                   ← 启动 uvicorn
│   └── stop.sh                    ← 停止 uvicorn
└── run_all_tests.sh

根目录（开发期 wrapper，不打入发布包）：
├── deploy.sh                      ← 唯一部署入口
├── start-docker.sh                → scripts/docker/start.sh
├── stop-docker.sh                 → scripts/docker/stop.sh
├── start-bare-metal.sh            → scripts/bare-metal/start.sh
├── stop-bare-metal.sh             → scripts/bare-metal/stop.sh
└── run_all_tests.sh               → scripts/run_all_tests.sh
```

设计原则：
- 每个脚本名自解释：install = 安装，start = 启动，stop = 停止，upgrade = 升级，uninstall = 卸载
- 发布流水线三个脚本形成清晰序列：build-image → make-release → publish-image
- 砍掉 L2 编排层（原 deploy-docker.sh / deploy-bare-metal.sh）：deploy.sh 的 dispatch 段直接调 L1
- 同目录无歧义命名

### 2. 砍掉 L2 层

原 deploy-docker.sh（~80 行）只做 install.sh + start.sh 两步调用。deploy-bare-metal.sh 同理（preflight + pip + models + start）。不值得单独文件。

deploy.sh dispatch 段直接编排 L1：

```bash
case "$MODE" in
    docker-online|docker-offline)
        bash "$SCRIPT_DIR/docker/install.sh" \
            --host-dir "$HOST_DIR" --release "$RELEASE_TAR" \
            ${IMAGE_TAR:+--image "$IMAGE_TAR"} \
            ${MODELS_TAR:+--models "$MODELS_TAR"} \
            ${TAG:+--tag "$TAG"}
        bash "$SCRIPT_DIR/docker/start.sh" --host-dir "$HOST_DIR"
        ;;
    bare-metal)
        bash "$SCRIPT_DIR/common/preflight.sh" --mode bare-metal
        $INSTALL_DEPS && (cd "$SOURCE_DIR" && pip install -r requirements.txt)
        [ "$MODELS_SOURCE" = "online" ] && \
            bash "$SCRIPT_DIR/common/download-models.sh" --target "$SOURCE_DIR/models"
        bash "$SCRIPT_DIR/bare-metal/start.sh" --source-dir "$SOURCE_DIR"
        ;;
esac
```

### 3. wizard.sh 交互流程

被 deploy.sh `source`（不是子进程），变量直接共享。

```
╔══════════════════════════════════════╗
║     Bishon V2 部署向导               ║
╚══════════════════════════════════════╝

[1/4] 部署模式
  [1] Docker 离线（本地 tar 加载）
  [2] Docker 在线（从 registry 拉取）
  [3] Bare-metal（无 Docker，直接 uvicorn）
  选择 [1-3]（默认 1）:

[2/4] 输入目录
  Docker 离线 — 检测发布包:
    目录: /home/user/deploy-bundle
    bishon-release-2.2.0.tar.gz       ✓
    bishon-cuda-image-2.2.0.tar       ✓
    bishon-models-2.2.0.tar.gz        ✓
  [回车确认，或输入路径]:

  Docker 在线 — 选 registry:
    [1] ghcr.io（海外）
    [2] 阿里云（国内推荐）
    [3] VPC 内网
  选择 [1-3]（默认 2）:

  Bare-metal — 选源码目录:
    检测到: /opt/Bishon/V2
  [回车确认，或输入路径]:

[3/4] 输出目录
  Docker — 安装位置: ./bishon-data
  Bare-metal — 不需要（直接用源码目录）
  [回车确认，或输入路径]:

[4/4] 确认
  模式:   docker-offline
  输入:   /home/user/deploy-bundle
  输出:   ./bishon-data
  开始部署？[Y/n]:
```

### 4. 启动后日志提示

docker/start.sh 成功后：
```
✓ 服务已启动（6 秒）
  Web 界面:  http://localhost:8777/bishon/
  API 检查:  http://localhost:8777/api/health

  日志:
    容器日志:  docker logs -f bishon
    应用日志:  tail -f <host-dir>/logs/debug_logs/debug.log
    问答日志:  tail -f <host-dir>/logs/qa_logs/qa.log

  停止: bash <host-dir>/scripts/docker/stop.sh --host-dir <host-dir>
  升级: bash <host-dir>/scripts/docker/upgrade.sh --host-dir <host-dir> --release <new-tar>
```

bare-metal/start.sh 成功后：
```
✓ 服务已启动
  Web 界面:  http://localhost:8777/bishon/
  API 检查:  http://localhost:8777/api/health

  日志:
    应用日志:  tail -f logs/debug_logs/debug.log
    问答日志:  tail -f logs/qa_logs/qa.log

  停止: bash scripts/bare-metal/stop.sh
```

### 5. docs/deployment.md 快速参考

| 操作 | Docker 离线 | Docker 在线 | Bare-metal |
|---|---|---|---|
| **部署** | `deploy.sh` → 选 docker-offline | `deploy.sh` → 选 docker-online | `deploy.sh` → 选 bare-metal |
| **启动** | `<host-dir>/scripts/docker/start.sh --host-dir <dir>` | 同左 | `scripts/bare-metal/start.sh` |
| **停止** | `<host-dir>/scripts/docker/stop.sh --host-dir <dir>` | 同左 | `scripts/bare-metal/stop.sh` |
| **升级** | `<host-dir>/scripts/docker/upgrade.sh --host-dir <dir> --release <tar>` | 同左 | `git pull && pip install -r requirements.txt` |
| **卸载** | `<host-dir>/scripts/docker/uninstall.sh --host-dir <dir>` | 同左 | `rm -rf <source-dir>` |
| **日志** | `tail -f <dir>/logs/debug_logs/debug.log` | 同左 | `tail -f logs/debug_logs/debug.log` |

### 6. 脚本头部统一格式

每个 .sh 文件开头：
```bash
#!/usr/bin/env bash
# <脚本名> — <一句话功能描述>
#
# 用法:
#   bash <脚本名> [参数]
```

### 7. 发布包布局

make-release.sh 产出：
```
deploy-bundle/
├── deploy.sh                      ← 入口（调 scripts/common/wizard.sh）
├── scripts/
│   ├── common/
│   │   ├── utils.sh
│   │   ├── wizard.sh
│   │   ├── download-models.sh
│   │   ├── preflight.sh
│   │   └── validate-manifest.sh
│   ├── docker/
│   │   ├── install.sh
│   │   ├── start.sh
│   │   ├── stop.sh
│   │   ├── upgrade.sh
│   │   ├── uninstall.sh
│   │   ├── build-image.sh
│   │   ├── make-release.sh
│   │   └── publish-image.sh
│   ├── bare-metal/
│   │   ├── start.sh
│   │   └── stop.sh
│   └── run_all_tests.sh
├── bishon-release-<ver>.tar.gz
├── bishon-cuda-image-<ver>.tar
├── bishon-models-<ver>.tar.gz
├── VERSION
└── .env.example
```

根 wrapper（start-docker.sh 等）不打入发布包——部署机从 `<host-dir>/scripts/` 运行。

### 8. CI 更新

`scripts/ci/shell-checks.sh` 的 find 范围：
```bash
find scripts/common scripts/docker scripts/bare-metal -name '*.sh' -type f
```

## 验证

1. `bash deploy.sh` 交互走完 4 步，全按回车 → 部署成功
2. `bash deploy.sh --non-interactive --dry-run` 打印完整计划
3. docker/start.sh 成功后输出包含日志路径 + 停止/升级命令
4. `bash scripts/ci/shell-checks.sh` 全绿
5. bats 通过
6. 发布包 `deploy-bundle/scripts/` 包含 common/ docker/ bare-metal/ 三层
7. docs/deployment.md 有快速参考表
