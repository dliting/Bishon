#!/usr/bin/env bash
# make-release.sh — assemble the offline release bundle for Bishon V2.
#
# Produces under <repo-root>/dist/:
#   bishon-release-<version>.tar.gz    — source + scripts (no python-env, no models)
#   bishon-pyenv-<version>.tar.gz      — python conda env (separate tarball)
#   bishon-cuda-image-<version>.tar    — docker save of bishon-cuda:<version>
#
# Usage:
#   bash scripts/docker/make-release.sh --version 2.1.0 [--conda-root /opt/miniconda3]
#
# Run inside WSL (Ubuntu 22.04) with the bishon conda env already created and
# all Python deps installed. The image must already exist (run build-image.sh
# first) — this script refuses to ship a release without its matching image.
#
# Hard constraint: WSL Ubuntu version MUST equal the image base (22.04), or
# the baked-in .so files in python-env will fail to load in the container.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

VERSION=""
CONDA_ROOT="${CONDA_ROOT:-/opt/miniconda3}"
OUTPUT_DIR=""           # default: $REPO_ROOT/dist
SKIP_PYENV=false
SKIP_MODELS=false
SKIP_IMAGE=false
SKIP_FRONTEND=false
SKIP_NODE=false
FORCE_FRONTEND=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        VERSION="$2";    shift 2 ;;
        --conda-root)     CONDA_ROOT="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        --force)          FORCE=true;      shift ;;
        --skip-pyenv)     SKIP_PYENV=true;     shift ;;
        --skip-models)    SKIP_MODELS=true;    shift ;;
        --skip-image)     SKIP_IMAGE=true;     shift ;;
        --skip-frontend)  SKIP_FRONTEND=true;  shift ;;
        --skip-node)      SKIP_NODE=true;      shift ;;
        --force-frontend) FORCE_FRONTEND=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--version <ver>] [--conda-root /opt/miniconda3] [flags]

SOURCE
  --version <ver>      Image and release tarball version, e.g. 2.1.0.
                       Default: read from VERSION file in repo root.
  --conda-root <path>  Path to miniconda3 installation (def: /opt/miniconda3).
  --output-dir <path>  Where release artifacts go (default: <repo>/dist).

COMPONENT SELECTION (all included by default)
  --skip-pyenv         Skip the python-env tarball (conda env copy ~7 GB).
  --skip-models        Skip models (Qwen3-Reranker + PaddleOCR ~2.5 GB).
  --skip-image         Skip the docker image tar (~3 GB).
  --skip-frontend      Skip the frontend build (use if dist is already built).
  --skip-node          Skip the node-env tarball (Node binary + node_modules, ~350 MB).
  --force-frontend     Rebuild frontend even if dist already exists.

ENVIRONMENT
  NODE_VERSION         Node.js version to download (default: 22.7.0 LTS).
  NODE_MIRROR          Download mirror (default: https://nodejs.org/dist/).
                       China-friendly: https://npmmirror.com/mirrors/node/
  NODE_ARCH            linux-x64 or linux-arm64 (default: auto from uname -m).

EXISTING RELEASE DIR
  --force              Overwrite existing files in release-<ver>/ dir.
                       Only updates changed files; previously-packaged
                       tarballs not part of THIS run are left untouched.
                       Without --force, the script refuses to run if the
                       output directory already exists.

Outputs (under --output-dir / default dist/):
  bishon-release-<ver>.tar.gz        source + scripts (no python-env, no models)
  bishon-pyenv-<ver>.tar.gz          python conda env (for install/upgrade --pyenv)
  bishon-models-<ver>.tar.gz         models only (for install/upgrade reuse)
  bishon-node-<ver>.tar.gz           Node binary + node_modules (optional)
  bishon-cuda-image-<ver>.tar        docker save tarball
  *.sha256                           matching checksum files
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Default VERSION from file if not passed on CLI (matches build-image.sh).
if [ -z "$VERSION" ]; then
    VERSION_FILE="$REPO_ROOT/VERSION"
    [ -f "$VERSION_FILE" ] || { echo "FATAL: $VERSION_FILE missing and --version not given" >&2; exit 1; }
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    [ -n "$VERSION" ] || { echo "FATAL: VERSION file is empty" >&2; exit 1; }
fi

ENV_SRC="$CONDA_ROOT/envs/bishon"
[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$REPO_ROOT/dist"
mkdir -p "$OUTPUT_DIR"
DIST="$OUTPUT_DIR/release-$VERSION"
DIST_TGZ="$DIST/bishon-release-$VERSION.tar.gz"
PYENV_TGZ="$DIST/bishon-pyenv-$VERSION.tar.gz"
MODELS_TGZ="$DIST/bishon-models-$VERSION.tar.gz"
NODE_TGZ="$DIST/bishon-node-$VERSION.tar.gz"
IMAGE_TAR="$DIST/bishon-cuda-image-$VERSION.tar"
IMAGE_TAG="bishon-cuda:$VERSION"

# Node toolchain selection (env vars overridable).
NODE_VERSION="${NODE_VERSION:-22.7.0}"
NODE_MIRROR="${NODE_MIRROR:-https://nodejs.org/dist/}"
NODE_ARCH="${NODE_ARCH:-$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')}"

export BISHON_LOG_TAG=release
# shellcheck source=../common/utils.sh
source "$(dirname "$0")/../common/utils.sh"

log() { bishon_log "$@"; }
die() { bishon_die "$@"; }

# --- 0. Pre-flight checks (delegates to scripts/docker/preflight.sh) ---------
PREFLIGHT_ARGS=(--version "$VERSION")
if $SKIP_PYENV && $SKIP_MODELS && $SKIP_IMAGE; then
    PREFLIGHT_ARGS+=(--src-only)
fi
bash "$(dirname "$0")/../common/preflight.sh" "${PREFLIGHT_ARGS[@]}" || \
    die "preflight failed. Fix the issues above before running make-release.sh."

# --- 1. Stage directory ------------------------------------------------------

log "staging at $DIST"
if [ -d "$DIST" ] && ! $FORCE; then
    die "$DIST already exists. Use --force to overwrite (rsync — only changed files are replaced)."
fi
mkdir -p "$DIST"

# --- 2. python-env (separate tarball) — skip with --skip-pyenv ---------------
if $SKIP_PYENV; then
    log "skipping python-env (--skip-pyenv)"
else
    log "copying python-env (~$(du -sh "$ENV_SRC" | cut -f1))"
    PYENV_STAGING="$(mktemp -d -p "$DIST" .tmp.pyenv.XXXXXX)"
    rsync -a \
        --exclude '__pycache__' \
        --exclude '*.pyc' \
        --exclude '*.pyo' \
        --exclude 'nvidia/cu13' \
        --exclude 'vllm' \
        --exclude 'spacy' \
        --exclude 'en_core_web*' \
        --exclude 'unstructured' \
        "$ENV_SRC/" "$PYENV_STAGING/python-env/"
    log "creating $PYENV_TGZ"
    (cd "$PYENV_STAGING" && tar -czf "$PYENV_TGZ.tmp" python-env && mv "$PYENV_TGZ.tmp" "$PYENV_TGZ")
    (cd "$DIST" && sha256sum "$(basename "$PYENV_TGZ")" > "$(basename "$PYENV_TGZ").sha256")
    rm -rf "$PYENV_STAGING"
    log "python-env tarball: $(du -sh "$PYENV_TGZ" | cut -f1)"
fi

# --- 3. Source code (MANIFEST-driven) ----------------------------------------
MANIFEST="$REPO_ROOT/release/MANIFEST"
[ -f "$MANIFEST" ] || \
    die "release/MANIFEST not found at $MANIFEST. Required to assemble release."

RSYNC_EXCLUDES=(
    --exclude '__pycache__'
    --exclude '*.pyc'
    --exclude '*.pyo'
    --exclude '.pytest_cache'
    --exclude '.ruff_cache'
    --exclude 'node_modules'
    --exclude 'front_end/dist'
    --exclude 'bishon_kernel/bishon_server/dist'
    --exclude '.git'
)

log "staging source from MANIFEST ($(wc -l < "$MANIFEST") lines)"
shipped=0
while IFS= read -r path; do
    src="$REPO_ROOT/$path"
    [ -e "$src" ] || die "MANIFEST references missing path: '$path'"
    dest_parent="$DIST/bishon/$(dirname "$path")"
    mkdir -p "$dest_parent"
    rsync -a "${RSYNC_EXCLUDES[@]}" "$src" "$dest_parent/"
    shipped=$((shipped + 1))
done < <(bishon_parse_manifest "$MANIFEST")
[ "$shipped" -gt 0 ] || die "MANIFEST produced zero staged paths. Is the file empty?"

# --- 3b. Frontend dist (ensures correct base path in built assets) ------------
# Source staging (step 3) excludes bishon_kernel/bishon_server/dist to avoid
# shipping stale builds. This step fills it in — either by building fresh or
# by copying the pre-built dist from the repo workspace.
STAGED_DIST_DIR="$DIST/bishon/bishon_kernel/bishon_server/dist"
STAGED_FRONTEND="$DIST/bishon/front_end"
REPO_DIST="$REPO_ROOT/bishon_kernel/bishon_server/dist/bishon/index.html"

# Helper: build frontend from staged source and copy to bishon_server/dist/.
build_frontend() {
    command -v npm >/dev/null || die "npm not found. Install Node.js or use --skip-frontend (dist must be pre-built)."
    [ -d "$STAGED_FRONTEND" ] || die "staged front_end/ not found — cannot build frontend."
    log "building frontend (npm ci && npm run build) ..."
    # npm ci installs from package-lock.json for reproducibility.
    # --legacy-peer-deps is needed due to known peer dependency conflicts
    # (pinia-plugin-persistedstate vs pinia vs vue version ranges).
    (cd "$STAGED_FRONTEND" && npm ci --legacy-peer-deps && npm run build) || \
        die "frontend build failed. Fix errors above or use --skip-frontend."
    # Vite outputs to front_end/dist/bishon/ (per vite.config.ts outDir).
    # Copy the contents of front_end/dist/ to bishon_server/dist/ where
    # FastAPI serves it. The dist/ dir contains the bishon/ subdirectory.
    mkdir -p "$STAGED_DIST_DIR"
    cp -a "$STAGED_FRONTEND/dist/." "$STAGED_DIST_DIR/"
    # Verify the build produced correct paths.
    if ! grep -qP 'src="/bishon/assets/|href="/bishon/assets/' "$STAGED_DIST_DIR/bishon/index.html" 2>/dev/null; then
        die "frontend build produced wrong base path. Check front_end/.env.production has VITE_APP_WEB_PREFIX=/bishon"
    fi
    log "frontend built and copied to bishon_server/dist/"
}

# Helper: validate base path in an index.html and copy to staged dist dir.
copy_valid_dist() {
    local src_index="$1" src_dir="$2" label="$3"
    if ! grep -qP 'src="/bishon/assets/|href="/bishon/assets/' "$src_index" 2>/dev/null; then
        return 1  # wrong base path
    fi
    mkdir -p "$STAGED_DIST_DIR"
    cp -a "$src_dir/." "$STAGED_DIST_DIR/"
    log "copied valid frontend dist $label (use --force-frontend to rebuild)"
    return 0
}

if $SKIP_FRONTEND; then
    # --skip-frontend: copy the pre-built dist from the repo workspace.
    if [ ! -f "$REPO_DIST" ]; then
        die "frontend dist missing at $REPO_DIST and --skip-frontend given. Build the frontend first (cd front_end && npm run build) or remove --skip-frontend."
    fi
    if ! copy_valid_dist "$REPO_DIST" "$REPO_ROOT/bishon_kernel/bishon_server/dist" "from repo"; then
        die "repo frontend dist has wrong base path (assets do not start with /bishon/assets/). Rebuild with VITE_APP_WEB_PREFIX=/bishon or remove --skip-frontend."
    fi
elif $FORCE_FRONTEND; then
    build_frontend
elif [ -f "$REPO_DIST" ]; then
    # Pre-built dist exists in repo workspace — try to copy; rebuild if wrong path.
    if ! copy_valid_dist "$REPO_DIST" "$REPO_ROOT/bishon_kernel/bishon_server/dist" "from repo"; then
        log "repo frontend dist has wrong base path — rebuilding instead"
        build_frontend
    fi
else
    # No pre-built dist — must build.
    build_frontend
fi

# --- 3c. Node toolchain (separate tarball) -----------------------------------
# Output bishon-node-<ver>.tar.gz: Node.js binary + Bishon frontend node_modules.
# install.sh --node <tar> extracts to $HOST_DIR/node-env/. entrypoint binds it.
if $SKIP_NODE; then
    log "skipping node-env (--skip-node)"
    mkdir -p "$DIST/node-env"
    echo "source-only release; node-env not included" > "$DIST/node-env/.skip-node"
else
    log "staging node-env (Node v$NODE_VERSION, arch $NODE_ARCH)"
    mkdir -p "$DIST/node-env"

    # 3c.1 Download Node.js linux-$NODE_ARCH tarball (cached at dist/.node-cache/)
    CACHE_DIR="$REPO_ROOT/dist/.node-cache"
    NODE_TARBALL="$CACHE_DIR/node-v$NODE_VERSION-linux-$NODE_ARCH.tar.gz"
    if [ ! -f "$NODE_TARBALL" ]; then
        mkdir -p "$CACHE_DIR"
        URL="${NODE_MIRROR}v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz"
        log "downloading $URL"
        if ! curl -fL --retry 3 --connect-timeout 30 -o "$NODE_TARBALL.tmp" "$URL"; then
            die "Node download failed. Try NODE_MIRROR=https://npmmirror.com/mirrors/node/ or pass --skip-node."
        fi
        mv "$NODE_TARBALL.tmp" "$NODE_TARBALL"
    else
        log "using cached $NODE_TARBALL"
    fi
    tar -xzf "$NODE_TARBALL" -C "$DIST/node-env/"

    # 3c.2 Copy node_modules (build host's front_end/node_modules/ is prepared by step 3b npm ci).
    if [ ! -d "$REPO_ROOT/front_end/node_modules" ]; then
        die "front_end/node_modules missing on build host. Run 'cd front_end && npm ci --legacy-peer-deps' first, or pass --skip-frontend + --skip-node for source-only release."
    fi
    log "copying node_modules (~$(du -sh "$REPO_ROOT/front_end/node_modules" 2>/dev/null | cut -f1 || echo '?'))"
    # Exclude only transient caches (.cache: vite/webpack intermediate state).
    # IMPORTANT: do NOT exclude `.bin/` — vite, vue-cli-service, etc. resolve their
    # shebangs through these symlinks; stripping them breaks `npm run build` in
    # the container. rsync -a preserves symlinks by default.
    rsync -a --exclude '.cache' "$REPO_ROOT/front_end/node_modules/" "$DIST/node-env/node_modules/"

    # 3c.3 Version stamp for deploy-side quick identification.
    echo "node-v$NODE_VERSION-linux-$NODE_ARCH" > "$DIST/node-env/.node-version"

    # 3c.4 Tarball + sha256.
    log "creating $NODE_TGZ"
    (cd "$DIST" && tar -czf "$NODE_TGZ.tmp" node-env && mv "$NODE_TGZ.tmp" "$NODE_TGZ")
    (cd "$DIST" && sha256sum "$(basename "$NODE_TGZ")" > "$(basename "$NODE_TGZ").sha256")
    log "node-env tarball: $(du -sh "$NODE_TGZ" | cut -f1)"
fi

# --- 4. Models — separate tarball (not in main release) ----------------------
# Models (~2.5 GB) change infrequently; shipping them in the main tarball
# forces every deploy to download them. Instead, produce a standalone
# models tarball that install.sh --models can optionally consume.
if $SKIP_MODELS; then
    log "skipping models (--skip-models)"
else
    log "copying models (~$(du -sh "$REPO_ROOT/models" 2>/dev/null | cut -f1 || echo '?'))"
    mkdir -p "$DIST/models"
    rsync -a --exclude '.git' "$REPO_ROOT/models/" "$DIST/models/"

    # Pre-generate tiktoken cache for offline deployment.
    # tiktoken downloads encoding files on first use; without internet
    # this fails silently and breaks document processing.
    log "pre-generating tiktoken cache for offline deployment"
    mkdir -p "$DIST/models/tiktoken_cache"
    TIKTOKEN_CACHE_DIR="$DIST/models/tiktoken_cache" \
        "$ENV_SRC/bin/python" -c "import tiktoken; tiktoken.get_encoding('cl100k_base')" \
        2>/dev/null && log "  tiktoken cl100k_base cached ($(du -sh "$DIST/models/tiktoken_cache" | cut -f1))" \
        || log "  WARNING: tiktoken cache generation failed (offline may break)"
    log "creating $MODELS_TGZ"
    tar -czf "$MODELS_TGZ" -C "$DIST" models
    (cd "$(dirname "$MODELS_TGZ")" && sha256sum "$(basename "$MODELS_TGZ")" > "$(basename "$MODELS_TGZ").sha256")
fi

# --- 5. Deploy bundle layout (self-contained, drop-in deployable) ------------
# Bundle root layout:
#   deploy.sh, start-docker.sh, ..., run_all_tests.sh   ← operator entry
#   scripts/{common,docker,bare-metal}/                 ← invoked by deploy.sh
# These are NOT under bishon/ — bishon/ is the runtime source (kernel, frontend,
# tests, docs, etc.) only.
mkdir -p "$DIST/scripts"
cp -a "$REPO_ROOT/scripts/common" "$DIST/scripts/"
cp -a "$REPO_ROOT/scripts/docker" "$DIST/scripts/"
cp -a "$REPO_ROOT/scripts/bare-metal" "$DIST/scripts/"
cp "$REPO_ROOT/scripts/run_all_tests.sh" "$DIST/scripts/"

# Root-level operator entry points
cp "$REPO_ROOT/deploy.sh"               "$DIST/"
cp "$REPO_ROOT/start-docker.sh"         "$DIST/"
cp "$REPO_ROOT/stop-docker.sh"          "$DIST/"
cp "$REPO_ROOT/start-bare-metal.sh"     "$DIST/"
cp "$REPO_ROOT/stop-bare-metal.sh"      "$DIST/"
cp "$REPO_ROOT/run_all_tests.sh"        "$DIST/"

cp "$REPO_ROOT/.env.example" "$DIST/"
cp "$REPO_ROOT/VERSION" "$DIST/"

# Generate README.md with file inventory and quick-start instructions.
BUILD_DATE="$(date +%Y-%m-%d)"
cat > "$DIST/README.md" <<EOREADME
# Bishon V2 离线部署包

版本: $VERSION
构建日期: $BUILD_DATE

## 文件清单

| 文件 | 大小 | 说明 |
|------|------|------|
| \`bishon-cuda-image-$VERSION.tar\` | ~3.1G | Docker 镜像 (CUDA 12.6 + Ubuntu 22.04 + Miniconda) |
| \`bishon-release-$VERSION.tar.gz\` | ~2M | Bishon 源码 + 前端 + 部署脚本 (不含 python-env) |
| \`bishon-pyenv-$VERSION.tar.gz\` | ~7G | Python 运行环境 (conda env, 首次安装必需) |
| \`bishon-models-$VERSION.tar.gz\` | ~1G | Reranker + OCR 模型权重 |
| \`bishon-node-$VERSION.tar.gz\` | ~160M | Node.js + 前端依赖 (可选, 用于前端热重建) |
| \`*.sha256\` | — | 各文件 SHA256 校验 |
| \`deploy.sh\` | — | 部署入口脚本 (交互式向导) |
| \`VERSION\` | — | 版本号 |

## 环境要求

- **OS**: Ubuntu 22.04 (WSL2 或原生 Linux)
- **GPU**: NVIDIA GPU + CUDA 12.6 驱动 + NVIDIA Container Toolkit
- **Docker**: 20.10+
- **磁盘**: >= 40G 可用空间 (ext4 文件系统, 不能是 9p/NTFS 挂载)
- **推理服务**: OpenAI 兼容的 LLM + Embedding 服务 (vLLM / Ollama 等)

## 快速部署

\`\`\`bash
# 1. 将整个目录拷贝到目标机器
scp -r release-$VERSION/ user@target:/opt/bishon-deploy/

# 2. 在目标机器上运行部署向导
cd /opt/bishon-deploy/release-$VERSION/
bash deploy.sh
\`\`\`

## 非交互式部署 (自动化/CI)

\`\`\`bash
bash deploy.sh --non-interactive \\
  --mode docker-offline \\
  --host-dir /opt/bishon-home \\
  --release bishon-release-$VERSION.tar.gz \\
  --pyenv bishon-pyenv-$VERSION.tar.gz \\
  --image bishon-cuda-image-$VERSION.tar \\
  --models bishon-models-$VERSION.tar.gz
\`\`\`

## 推理服务配置

Bishon 通过 \`.env\` 中的以下变量连接推理服务 (部署后在 host-dir 中编辑):

\`\`\`bash
# LLM (OpenAI 兼容 API)
OPENAI_API_BASE=http://localhost:8000/v1       # vLLM / Ollama 地址
OPENAI_API_MODEL_NAME=Qwen3.5-4B

# Embedding
EMBEDDING_API_BASE=http://localhost:8001/v1/embeddings
EMBEDDING_MODEL_NAME=Qwen3-Embedding-0.6B
\`\`\`

> Docker 模式下推理服务运行在宿主机时, 需根据网络模式修改地址:
> - bridge (默认): 改为 Docker 网桥 IP, 如 \\\`http://172.17.0.1:8000/v1\\\`
> - host (\\\`--network host\\\`): 可直接用 \\\`localhost\\\`
> - 远程服务: 使用实际 IP

## 常用操作

\`\`\`bash
# 启动
bash start-docker.sh --host-dir /opt/bishon-home

# 停止
bash stop-docker.sh --host-dir /opt/bishon-home

# 查看日志
docker logs -f bishon

# 健康检查
curl http://localhost:8777/api/health
\`\`\`

## 校验文件完整性

\`\`\`bash
for f in *.sha256; do sha256sum -c "\$f"; done
\`\`\`
EOREADME
log "generated README.md"

# --- 6. Main tarball ---------------------------------------------------------
# Write the tarball outside $DIST/ then mv it in, so tar doesn't see its own
# output being created (avoids "file changed as we read it" warnings).
TMP_TGZ="$OUTPUT_DIR/bishon-release-$VERSION.tar.gz.tmp"
log "creating $DIST_TGZ (~this step is slow due to gzip)"
tar -czf "$TMP_TGZ" -C "$DIST" \
    --exclude 'bishon-release-*.tar.gz'        \
    --exclude 'bishon-release-*.tar.gz.sha256' \
    --exclude 'bishon-models-*.tar.gz'        \
    --exclude 'bishon-models-*.tar.gz.sha256' \
    --exclude 'bishon-pyenv-*.tar.gz'         \
    --exclude 'bishon-pyenv-*.tar.gz.sha256'  \
    --exclude 'bishon-node-*.tar.gz'          \
    --exclude 'bishon-node-*.tar.gz.sha256'   \
    --exclude 'bishon-cuda-image-*.tar'       \
    --exclude 'node-env'                       \
    --exclude 'python-env'                     \
    --exclude 'models'                         \
    .
mv "$TMP_TGZ" "$DIST_TGZ"
(cd "$(dirname "$DIST_TGZ")" && sha256sum "$(basename "$DIST_TGZ")" > "$(basename "$DIST_TGZ").sha256")

# --- 7. Image tar — skip with --skip-image ----------------------------------
if $SKIP_IMAGE; then
    log "skipping docker image tar (--skip-image)"
else
    log "exporting image to $IMAGE_TAR (docker save)"
    docker save "$IMAGE_TAG" -o "$IMAGE_TAR"
fi

# --- 8. Summary --------------------------------------------------------------
log "done. Artifacts:"
log "  $DIST_TGZ       ($(du -h "$DIST_TGZ" | cut -f1))"
log "  $DIST_TGZ.sha256"
if ! $SKIP_PYENV && [ -f "$PYENV_TGZ" ]; then
    log "  $PYENV_TGZ       ($(du -h "$PYENV_TGZ" | cut -f1))"
    log "  $PYENV_TGZ.sha256"
fi
if ! $SKIP_MODELS; then
    log "  $MODELS_TGZ     ($(du -h "$MODELS_TGZ" | cut -f1))"
    log "  $MODELS_TGZ.sha256"
fi
if ! $SKIP_NODE && [ -f "$NODE_TGZ" ]; then
    log "  $NODE_TGZ       ($(du -h "$NODE_TGZ" | cut -f1))"
    log "  $NODE_TGZ.sha256"
fi
if ! $SKIP_IMAGE; then
    log "  $IMAGE_TAR      ($(du -h "$IMAGE_TAR" | cut -f1))"
fi
log ""
log ""
log "Distribute the whole directory to the deploy host:"
log "  $DIST"
log "On the deploy host, cd into it and run:"
log "  bash deploy.sh"

# --- 9. Cleanup staging directories ------------------------------------------
# The release directory should only contain deployable artifacts (tarballs,
# checksums, README, deploy scripts). Intermediate staging dirs (bishon/,
# models/, node-env/, scripts/) are already packed into their respective
# tarballs and must be removed to keep the directory clean for distribution.
log "cleaning up staging directories"
rm -rf "$DIST/bishon" "$DIST/models" "$DIST/node-env" "$DIST/scripts"
log "release directory ready for distribution: $DIST"
