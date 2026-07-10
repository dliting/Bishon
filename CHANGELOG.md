# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- README: "Who is this for", "Sizing", "Scaling beyond" sections — target audience, sizing reference numbers, extension points for adapting the codebase to larger workloads.
- README + NOTICE: softened QAnything attribution wording to acknowledge borrowed implementation details.

## [2.0.0] - 2026-07-07

### Added
- Initial public release of Bishon V2.
- Local-first knowledge base QA system: FastAPI + FAISS + SQLite + PaddleOCR + in-process Rerank.
- Vue 3 + Vite + TypeScript + Ant Design Vue frontend with SSE streaming chat.
- Multi-format document ingestion: PDF, Word (docx), PPT, TXT, images (jpg/png/jpeg), CSV, Excel, EML, Markdown, web URLs.
- Document traceability: click a source document to open the original file.
- Health endpoint (`GET /api/health`) for deployment probes.
- MIT License, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY policy.

### Architecture
- Replaces the original Docker Compose stack (Milvus + etcd + MinIO + Elasticsearch + MySQL + Triton) with a single-process deployment.
- FAISS (file-persisted) instead of Milvus.
- SQLite (WAL mode) instead of MySQL.
- SQLite FTS5 (default off) instead of Elasticsearch.
- External OpenAI-compatible HTTP API for LLM and Embedding (Ollama / vLLM / OpenAI).
- In-process Qwen3-Reranker (transformers) instead of Triton rerank microservice.
- In-process PaddleOCR 3.x instead of OCR microservice.
- FastAPI + uvicorn instead of Sanic.

[Unreleased]: https://github.com/dliting/Bishon/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/dliting/Bishon/releases/tag/v2.0.0
