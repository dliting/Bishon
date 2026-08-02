"""Lightweight health probes for each Bishon service.

Each probe returns ``(status: str, detail: str, latency_ms: float)``.
``status`` should be one of the STATUS_* constants from status_store.
Network probes use ``httpx`` with a short timeout; in-process services
are checked by state inspection only (no GPU/CPU load).
"""
import logging
import os
import time
from collections.abc import Callable

import httpx

from bishon_kernel.monitoring.status_store import (
    SERVICE_EMBEDDING,
    SERVICE_FAISS,
    SERVICE_LLM,
    SERVICE_OCR,
    SERVICE_RERANK,
    SERVICE_SQLITE,
    STATUS_DISABLED,
    STATUS_HEALTHY,
    STATUS_UNHEALTHY,
)

logger = logging.getLogger(__name__)

PROBE_TIMEOUT_SECONDS = 5

# ── LLM probe ────────────────────────────────────────────────────────

def probe_llm(local_doc_qa) -> tuple[str, str, float]:  # noqa: ARG001
    """Check LLM service reachability.

    - Ollama: ``GET /api/tags``
    - OpenAI / MiniMax: ``GET /v1/models``
    """
    from bishon_kernel.connector.llm.llm_for_openai_api import (
        LLM_PROVIDER, OPENAI_API_BASE, OPENAI_API_KEY, OPENAI_API_MODEL_NAME,
    )

    base_url = (OPENAI_API_BASE or "").rstrip("/")
    provider = LLM_PROVIDER

    if provider == "ollama":
        # Ollama native endpoint
        api_base = base_url
        if api_base.endswith("/v1"):
            api_base = api_base[:-3]
        url = f"{api_base}/api/tags"
    else:
        # OpenAI-compatible /v1/models (requires auth on some providers)
        url = f"{base_url}/models" if base_url else ""

    if not url:
        return STATUS_UNHEALTHY, f"{provider}: no API base URL configured", 0.0

    headers = {}
    if provider != "ollama" and OPENAI_API_KEY:
        headers["Authorization"] = f"Bearer {OPENAI_API_KEY}"

    start = time.time()
    try:
        with httpx.Client(timeout=PROBE_TIMEOUT_SECONDS) as client:
            resp = client.get(url, headers=headers)
        latency = (time.time() - start) * 1000
        resp.raise_for_status()
        return STATUS_HEALTHY, f"{provider} {OPENAI_API_MODEL_NAME} @ {base_url}", latency
    except Exception as e:
        latency = (time.time() - start) * 1000
        return STATUS_UNHEALTHY, f"{provider}: {e}", latency


# ── Embedding probe ──────────────────────────────────────────────────

def probe_embedding(local_doc_qa) -> tuple[str, str, float]:  # noqa: ARG001
    """Check embedding service reachability via ``GET /v1/models``."""
    from bishon_kernel.connector.embedding.openai_embedding import (
        BASE_URL, EMBEDDING_API_KEY, EMBEDDING_MODEL_NAME,
    )

    base_url = (BASE_URL or "").rstrip("/")
    url = f"{base_url}/models" if base_url else ""

    if not url:
        return STATUS_UNHEALTHY, "no embedding API base URL configured", 0.0

    headers = {}
    if EMBEDDING_API_KEY and EMBEDDING_API_KEY != "EMPTY":
        headers["Authorization"] = f"Bearer {EMBEDDING_API_KEY}"

    start = time.time()
    try:
        with httpx.Client(timeout=PROBE_TIMEOUT_SECONDS) as client:
            resp = client.get(url, headers=headers)
        latency = (time.time() - start) * 1000
        resp.raise_for_status()
        return STATUS_HEALTHY, f"{EMBEDDING_MODEL_NAME} @ {base_url}", latency
    except Exception as e:
        latency = (time.time() - start) * 1000
        return STATUS_UNHEALTHY, f"embedding: {e}", latency


# ── Rerank probe ─────────────────────────────────────────────────────

def probe_rerank(local_doc_qa) -> tuple[str, str, float]:
    """Check rerank availability (state-only, no model loading)."""
    from bishon_kernel.connector.rerank.rerank_client import RERANK_ENABLED, RERANK_MODEL_PATH

    if not RERANK_ENABLED:
        return STATUS_DISABLED, "disabled (RERANK_ENABLED=false)", 0.0

    if not os.path.exists(RERANK_MODEL_PATH):
        return STATUS_UNHEALTHY, f"model not found: {RERANK_MODEL_PATH}", 0.0

    # Check if the backend actually loaded
    backend = getattr(local_doc_qa, "rerank_backend", None)
    if backend is None or not getattr(backend, "enabled", False):
        return STATUS_UNHEALTHY, "rerank backend failed to initialize", 0.0

    return STATUS_HEALTHY, f"{RERANK_MODEL_PATH} ({backend.model_type})", 0.0


# ── OCR probe ────────────────────────────────────────────────────────

def probe_ocr(local_doc_qa) -> tuple[str, str, float]:
    """Check OCR availability (state-only)."""
    engine = getattr(local_doc_qa, "ocr_engine", None)
    if engine is None:
        return STATUS_UNHEALTHY, "PaddleOCR not initialized", 0.0

    gpu_info = ""
    try:
        from bishon_kernel.utils.gpu_utils import can_use_ocr_gpu
        gpu_info = " GPU" if can_use_ocr_gpu() else " CPU"
    except Exception:
        pass

    return STATUS_HEALTHY, f"PaddleOCR{gpu_info}", 0.0


# ── FAISS probe ──────────────────────────────────────────────────────

def probe_faiss(local_doc_qa) -> tuple[str, str, float]:
    """Check FAISS vector store availability (state-only)."""
    from bishon_kernel.configs.model_config import FAISS_EMBEDDING_DIM

    faiss_kbs = getattr(local_doc_qa, "faiss_kbs", [])
    count     = len(faiss_kbs)

    if count == 0:
        return STATUS_HEALTHY, f"{FAISS_EMBEDDING_DIM}-dim, 0 collections (idle)", 0.0

    return STATUS_HEALTHY, f"{FAISS_EMBEDDING_DIM}-dim, {count} collection(s)", 0.0


# ── SQLite probe ─────────────────────────────────────────────────────

def probe_sqlite(local_doc_qa) -> tuple[str, str, float]:
    """Check SQLite database connectivity via ``SELECT 1``.

    KnowledgeBaseManager uses one-shot connections (sqlite3.connect per query),
    so we open a fresh connection here using the module-level DB_PATH that
    ``_execute`` itself uses. This mirrors how the app actually talks to SQLite
    rather than probing a persistent connection that doesn't exist.
    """
    kb_manager = getattr(local_doc_qa, "kb_manager", None)
    if kb_manager is None:
        return STATUS_UNHEALTHY, "KnowledgeBaseManager not initialized", 0.0

    # Resolve DB_PATH from the sqlite_client module (set by KnowledgeBaseManager.__init__
    # and adjustable via monkeypatch in tests).
    try:
        from bishon_kernel.connector.database.sqlite import sqlite_client as sqlite_mod
    except ImportError:
        return STATUS_UNHEALTHY, "sqlite_client module not importable", 0.0
    db_path = getattr(sqlite_mod, "DB_PATH", None)
    if not db_path:
        return STATUS_UNHEALTHY, "sqlite_client.DB_PATH not configured", 0.0

    import sqlite3
    start = time.time()
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        try:
            cursor = conn.execute("SELECT 1")
            cursor.fetchone()
        finally:
            conn.close()
        latency = (time.time() - start) * 1000
        return STATUS_HEALTHY, db_path, latency
    except Exception as e:
        latency = (time.time() - start) * 1000
        return STATUS_UNHEALTHY, f"SQLite: {e}", latency


# ── Registry ─────────────────────────────────────────────────────────

ALL_PROBES: dict[str, Callable] = {
    SERVICE_LLM:       probe_llm,
    SERVICE_EMBEDDING: probe_embedding,
    SERVICE_RERANK:    probe_rerank,
    SERVICE_OCR:       probe_ocr,
    SERVICE_FAISS:     probe_faiss,
    SERVICE_SQLITE:    probe_sqlite,
}
