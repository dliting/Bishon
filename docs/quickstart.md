# Quick Start

## Who is this for

Individuals and small-to-medium teams (up to ~50 people) who need a
self-hosted knowledge base without standing up a microservice stack. Tested
on a single workstation with up to ~50,000 documents / ~2M chunks. For
enterprise / SaaS workloads or million-document corpora, consider NetEase
QAnything, RAGFlow, or Dify instead.

## Prerequisites

- **Linux x86_64** (WSL2 Ubuntu 22.04 recommended for Windows users)
- **Docker** + **NVIDIA Container Toolkit** (Docker mode only)
- An **LLM service** exposing an OpenAI-compatible API (Ollama / vLLM / OpenAI)
- An **Embedding service** exposing an OpenAI-compatible API
- (Optional) NVIDIA GPU + CUDA

## Deploy with `deploy.sh` (Recommended)

`deploy.sh` is the single entry point for all deployment modes. It runs an
interactive wizard that guides you through mode selection, configuration, and
installation.

```bash
# From the release directory (contains deploy.sh + tarballs)
bash deploy.sh
```

The wizard will ask:

1. **Mode** — `docker-online` (pull image from registry), `docker-offline`
   (load image from local tar), or `bare-metal` (no Docker)
2. **Host directory** — where state lives (default: `/opt/bishon-home`,
   must be on ext4 — not NTFS/9p)
3. **Image source** — registry (ghcr.io / Aliyun) or local tarball
4. **Models source** — online download, local tarball, existing directory, or skip
5. **Confirm** — review and proceed

After installation, `deploy.sh` automatically starts the service.

### Non-interactive mode (CI / batch deploy)

```bash
bash deploy.sh \
    --non-interactive \
    --mode docker-online \
    --host-dir /opt/bishon-home \
    --release bishon-release-2.3.0.tar.gz \
    --pyenv bishon-pyenv-2.3.0.tar.gz \
    --pull --registry aliyun \
    --models-source skip
```

`--dry-run` runs through all steps without executing.

## Start / Stop

After initial deployment, use the mode-specific scripts:

### Docker mode

```bash
bash /opt/bishon-home/start-docker.sh --host-dir /opt/bishon-home
bash /opt/bishon-home/stop-docker.sh  --host-dir /opt/bishon-home
```

### Bare-metal mode

```bash
bash start-bare-metal.sh
bash stop-bare-metal.sh
```

## Configure

Edit `/opt/bishon-home/.env` (Docker mode) or `.env` in the source directory
(bare-metal mode) to set:

```bash
OPENAI_API_BASE=http://your-llm-host:8000/v1
EMBEDDING_API_BASE=http://your-embedding-host:8000/v1
```

**Important**: Do not use `host.docker.internal` — it does not work reliably
in WSL2 or nested virtualization. Use the actual IP or `localhost` with
`--network host`.

## Verify

```bash
curl http://localhost:8777/api/health
```

Open <http://localhost:8777/bishon/> for the UI.

## Next steps

- [Full deployment guide](deployment.md) — detailed instructions, upgrade, troubleshooting
- [Development environment setup](dev-environment.md) — for contributors
