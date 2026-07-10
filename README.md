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

## Who is this for

Bishon V2 is designed for **individuals and small-to-medium teams** who need a
self-hosted, privacy-friendly knowledge base without standing up a
microservice stack:

- **Individual researchers / engineers** — personal notes, papers, technical
  docs, all searchable and citable from a single chat box.
- **Small teams (3–10 people)** — shared project docs, meeting notes, internal
  wikis. Each member runs their own Bishon instance against a shared LLM
  endpoint, or one instance serves the team behind a reverse proxy.
- **Medium teams (10–50 people)** — department-level knowledge base. Works on
  a single beefy workstation; for higher concurrency see *Scaling beyond*
  below.

**Out of scope** by design (no built-in support today):

- Multi-tenant SaaS with authentication / authorization.
- High-concurrency (> 10 simultaneous Q&A streams) production traffic.
- Million-document corpora (single-machine FAISS tops out well before that).

For those workloads, consider NetEase QAnything, RAGFlow, or Dify — they fit
the enterprise / SaaS end of the spectrum. Bishon V2 trades horizontal scale
for installation simplicity.

## Sizing (reference numbers)

Tested configurations on a single workstation. Numbers assume Qwen3-Reranker
disabled and CPU-only OCR (set `RERANK_ENABLED=false`, `OCR_USE_GPU=false`):

| Workload | Documents | Total chunks | RAM | Disk | Notes |
|----------|-----------|--------------|-----|------|-------|
| Personal | 100–1,000 | < 50k | 8 GB | 20 GB | Default config; works on a laptop |
| Small team | 1,000–10,000 | 50k–500k | 16 GB | 100 GB | Rerank on; CPU FAISS is fine |
| Medium team | 10,000–50,000 | 500k–2M | 32 GB | 500 GB | Enable FAISS-GPU + Rerank GPU; expect slower ingestion |

Hard limits in the current codebase:

- Single file upload: **30 MB** (documented in the UI; not hard-enforced in code).
- Single image upload: **5 MB** (same — UI documentation only).
- Concurrent uploads: thread pool = 4 (`bishon_kernel/bishon_server/handler.py:_executor`).
- Q&A concurrency: same thread pool; one streaming Q&A blocks one worker for its duration.
- Per-user FAISS index lives in one file under `BISHON_DB/faiss/{user_id}.faiss` — rebuild required if `FAISS_EMBEDDING_DIM` changes.

If you outgrow these limits, see *Scaling beyond* below.

## Scaling beyond (extension points)

The codebase is intentionally small and modular. To adapt it for larger or
different workloads:

| Goal | What to change |
|------|----------------|
| Pluggable vector store (Milvus / Qdrant / pgvector) | Implement the interface in `bishon_kernel/connector/database/faiss/faiss_client.py` (`FaissClient`) behind a new class. ~400 LOC. |
| Pluggable metadata store (PostgreSQL / MySQL) | Replace `bishon_kernel/connector/database/sqlite/sqlite_client.py` (`KnowledgeBaseManager`). Keep the public method names so handlers don't change. |
| Add a new LLM provider (Anthropic / Gemini / MiniMax) | Subclass `BaseAdapter` in `bishon_kernel/connector/llm/adapters/`. Implement `chat()` and register it in `LLM_PROVIDER` dispatch (`bishon_kernel/connector/llm/llm_for_openai_api.py`). |
| Add a new document loader (audio / video / epub) | Add a loader under `bishon_kernel/utils/loader/` and wire it into the dispatch in `bishon_kernel/core/local_file.py`. |
| Swap PaddleOCR for a cloud OCR API | Replace the OCR callable in `bishon_kernel/core/local_doc_qa.py:LocalDocQA._ocr_callable`. Same shape — takes image data, returns a list of text strings. |
| Add authentication (API keys / OIDC) | Add a FastAPI dependency / middleware in `bishon_kernel/bishon_server/app.py`. The handlers read `user_id` from the request body; surface it from `request.state.user` once auth is in place. |
| Horizontal scaling | The FAISS index is a file; either (a) shard by `user_id` across N replicas behind a load balancer, or (b) move to a shared vector store (see first row). SQLite WAL mode supports concurrent reads; for heavy writes, move metadata to PostgreSQL. |
| Bigger uploads | No hard limit today; the 30 MB / 5 MB caps are UI-only. Add an explicit check in the FastAPI handler (`bishon_kernel/bishon_server/handler.py:upload_files`) and a matching validator in `front_end/src/components/FileUploadDialog.vue`. |

A high-level architecture map and per-module notes live under `docs/design/`.

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

Architecture and several implementation details inspired by
[NetEase QAnything](https://github.com/netease-youdao/QAnything). See `NOTICE`
for details.

## Trademark notice

"Bishon" is used as a project name. If you have a conflicting trademark,
please open an Issue.

## License

[MIT](LICENSE) — Copyright (c) 2026 The Bishon V2 Authors.
