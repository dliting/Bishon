# Bishon V2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/)
[![Vue 3](https://img.shields.io/badge/Vue-3.3-brightgreen.svg)](https://vuejs.org/)
[![CI](https://github.com/dliting/Bishon/actions/workflows/ci.yml/badge.svg)](https://github.com/dliting/Bishon/actions/workflows/ci.yml)

**A local-first knowledge base QA system.** No Docker, no cloud, no microservice
zoo — just FastAPI + FAISS + SQLite running on bare metal.

English | [简体中文](README.zh-CN.md)

---

## Features

- **Single-process deployment** — replaces the original 6+ container Docker
  Compose stack with one `uvicorn` command.
- **Multi-format ingestion** — PDF, Word (docx), PPT, TXT, images (jpg/png/jpeg),
  CSV, Excel, EML, Markdown, and arbitrary web URLs.
- **In-process PaddleOCR 3.x** — no separate OCR microservice.
- **In-process Rerank** — Qwen3-Reranker via `transformers`, no Triton.
- **External LLM / Embedding** — bring your own Ollama, vLLM, or any
  OpenAI-compatible endpoint.
- **Optional GPU acceleration** — FAISS, Rerank, and OCR all respect
  per-component env flags.
- **Document traceability** — click any source document to open the original
  file in your browser.
- **SSE streaming chat** — answers stream token-by-token from the LLM.

## Screenshots

<!-- TODO: replace with real screenshots before publishing. -->

```
[Chat view with streaming answer + source documents panel]
[Knowledge base management view]
[Upload modal with multi-format support]
```

## Architecture

```
Knowledge Base Service (FastAPI, port 8777)
├── FAISS (vector retrieval)
├── SQLite + FTS5 (metadata + full-text)
├── PaddleOCR (document recognition)
└── Rerank (in-process transformers)
        │
        │ HTTP (via configuration)
        ▼
External model services (started independently, reusable)
├── Ollama / OpenAI API (LLM)
└── Ollama / OpenAI API (Embedding)
```

### Project layout

```
Bishon/V2/
├── bishon_kernel/          Core code
│   ├── configs/            Configuration (single .env entry point)
│   ├── connector/          Data connectors
│   │   ├── database/       FAISS + SQLite
│   │   ├── embedding/      OpenAI-compatible Embedding
│   │   ├── rerank/         In-process Rerank
│   │   └── llm/            OpenAI-compatible LLM
│   ├── core/               Core QA + file processing
│   ├── bishon_server/      FastAPI layer + served frontend dist
│   └── utils/              Utilities
├── BISHON_DB/              Data directory (auto-created)
│   ├── metadata.db         SQLite metadata
│   ├── faiss/              FAISS vector index
│   └── content/            Uploaded files
├── logs/                   Logs
├── .env                    Configuration (gitignored; copy from .env.example)
├── requirements.txt        Python dependencies
├── start.sh                Linux startup script
└── start.bat               Windows startup script
```

## Requirements

- Python 3.11+
- An LLM service exposing an OpenAI-compatible API (Ollama / vLLM / OpenAI)
- An Embedding service exposing an OpenAI-compatible API (Ollama / OpenAI)
- (Optional) NVIDIA GPU + CUDA for acceleration

## Quick start

```bash
# 1. Create the conda environment
conda create -n bishon python=3.11 -y
conda activate bishon

# 2. Install Python dependencies
pip install -r requirements.txt

# 3. Configure
cp .env.example .env
# Edit .env: set OPENAI_API_BASE / OPENAI_API_KEY / EMBEDDING_API_BASE / etc.

# 4. Build the frontend (only required if dist/ is not present)
cd front_end && npm ci && npm run build && cd ..

# 5. Run
./start.sh        # Linux / WSL
start.bat         # Windows
```

The service is now live at <http://localhost:8777>. Open <http://localhost:8777/bishon/>
for the UI or <http://localhost:8777/api/docs> for the API overview.

## Configuration (`.env`)

See `.env.example` for the full template. Highlights:

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENAI_API_BASE` | LLM service URL | `http://localhost:11434/v1` |
| `OPENAI_API_MODEL_NAME` | LLM model name | `qwen3:14b` |
| `OPENAI_API_KEY` | LLM API key | `EMPTY` (for local Ollama) |
| `OPENAI_API_CONTEXT_LENGTH` | LLM context window | `8192` |
| `LLM_PROVIDER` | Adapter selection: `openai` / `ollama` / `minimax` | `openai` |
| `EMBEDDING_API_BASE` | Embedding service URL | `http://localhost:11434/v1/embeddings` |
| `EMBEDDING_MODEL_NAME` | Embedding model | `qwen3-embedding:0.6b` |
| `RERANK_MODEL_PATH` | Local Rerank model path | `models/Qwen3-Reranker-0.6B` |
| `RERANK_ENABLED` | Enable in-process rerank | `false` |
| `FAISS_EMBEDDING_DIM` | Must match your embedding model | `1024` |
| `DOC_SCORE_THRESHOLD` | Min mean relevance for docs returned | `0.65` |
| `VECTOR_DB_USE_GPU` / `RERANK_USE_GPU` / `OCR_USE_GPU` | Per-component GPU flags | `true` |

## API overview

All endpoints are documented at `GET /api/docs`. See `docs/API.md` for full
field-level documentation.

| Method | Path | Description |
|--------|------|-------------|
| GET    | `/api/health` | Health probe |
| POST   | `/api/local_doc_qa/new_knowledge_base` | Create a KB |
| POST   | `/api/local_doc_qa/upload_files` | Upload files |
| POST   | `/api/local_doc_qa/upload_weblink` | Upload a URL |
| POST   | `/api/local_doc_qa/local_doc_chat` | Chat (supports SSE streaming) |
| POST   | `/api/local_doc_qa/list_knowledge_base` | List KBs |
| POST   | `/api/local_doc_qa/list_files` | List files |
| POST   | `/api/local_doc_qa/get_total_status` | Status summary |
| POST   | `/api/local_doc_qa/clean_files_by_status` | Clean files by status |
| POST   | `/api/local_doc_qa/delete_files` | Delete files |
| POST   | `/api/local_doc_qa/delete_knowledge_base` | Delete a KB |
| POST   | `/api/local_doc_qa/rename_knowledge_base` | Rename a KB |
| GET    | `/api/local_doc_qa/download_file/{file_id}` | Download original file (traceability) |
| GET    | `/api/docs` | API overview (plain text) |

## Comparison with traditional RAG stacks

Bishon V2 swaps the heavyweight microservice stack for a single-process
deployment that fits comfortably on a workstation:

| Component | Traditional (Docker Compose) | Bishon V2 |
|-----------|------------------------------|-----------|
| Vector store | Milvus + etcd + MinIO | FAISS (file-persisted) |
| Metadata | MySQL | SQLite (WAL mode) |
| Full-text search | Elasticsearch | SQLite FTS5 (off by default) |
| Embedding | Triton (local GPU) | External HTTP (Ollama / OpenAI) |
| Rerank | Triton (local GPU) | In-process Qwen3-Reranker |
| LLM | FastChat / vLLM / FasterTransformer | External HTTP (Ollama / OpenAI) |
| OCR | PaddleOCR microservice | In-process PaddleOCR 3.x |
| Web framework | Sanic | FastAPI |
| Deployment | Docker Compose (6+ containers) | Single command |

## Roadmap

- **v2.0** (this release): bare-metal single-process deployment, MIT license,
  bilingual docs, GitHub Actions CI.
- **v2.1**: optional Docker / docker-compose deployment, MkDocs documentation
  site on GitHub Pages.
- **v2.2**: multimodal ingestion (audio / video transcription), pluggable
  storage backends.

## Acknowledgements

Architecture inspired by [NetEase QAnything](https://github.com/netease-youdao/QAnything).
All code in this repository has been rewritten from scratch. See `NOTICE` for
details.

## Trademark notice

"Bishon" is used as a project name. If you have a conflicting trademark,
please open an Issue.

## License

[MIT](LICENSE) — Copyright (c) 2026 The Bishon V2 Authors.
