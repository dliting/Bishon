# Quick Start

> Placeholder — see [README.md](https://github.com/dliting/Bishon/blob/main/README.md)
> for the canonical quick-start guide. This page will be expanded in v2.1
> when the MkDocs site goes live on GitHub Pages.

## Who is this for

Individuals and small-to-medium teams (up to ~50 people) who need a
self-hosted knowledge base without standing up a microservice stack. Tested
on a single workstation with up to ~50,000 documents / ~2M chunks. For
enterprise / SaaS workloads or million-document corpora, consider NetEase
QAnything, RAGFlow, or Dify instead. See the README *Scaling beyond* section
for extension points.

## Prerequisites

- Python 3.11+
- An LLM service exposing an OpenAI-compatible API (Ollama / vLLM / OpenAI)
- An Embedding service exposing an OpenAI-compatible API
- (Optional) NVIDIA GPU + CUDA

## Install

```bash
conda create -n bishon python=3.11 -y
conda activate bishon
pip install -r requirements.txt
```

## Configure

```bash
cp .env.example .env
# Edit .env to point at your LLM / Embedding endpoints.
```

## Build frontend

```bash
cd front_end && npm ci && npm run build && cd ..
```

## Run

```bash
./start.sh        # Linux / WSL
start.bat         # Windows
```

Open <http://localhost:8777/bishon/> for the UI.
