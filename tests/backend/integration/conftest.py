"""API integration test fixtures."""
import os
import time
from unittest.mock import MagicMock

import httpx
import pytest
from httpx import ASGITransport


def _drain_background_executor(timeout: float = 5.0) -> None:
    """Block until handler._executor finishes all queued tasks.

    handler.upload_files / upload_weblink submit `_safe_insert` to a module-level
    ThreadPoolExecutor (`_executor`) and return immediately. If pytest's
    `tmp_path` cleanup runs first, the bg thread later tries to UPDATE File on
    a DB file that's already been deleted → SQLite auto-creates an empty file
    → "no such table: File" error in teardown.

    Submitting a sentinel task and waiting on its Future guarantees FIFO
    completion of all previously-queued tasks before we let pytest clean up.
    """
    try:
        from bishon_kernel.bishon_server.handler import _executor
    except Exception:
        return  # handler not imported yet — nothing to drain
    try:
        future = _executor.submit(lambda: None)
    except RuntimeError:
        return  # executor already shut down
    deadline = time.monotonic() + timeout
    while not future.done() and time.monotonic() < deadline:
        time.sleep(0.02)


@pytest.fixture
async def api_client(tmp_path, monkeypatch):
    """FastAPI async test client with isolated SQLite/FAISS and mocked external services"""
    import bishon_kernel.connector.database.faiss.faiss_client as faiss_mod
    import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod

    # Isolated DB
    db_dir = str(tmp_path / "db")
    os.makedirs(db_dir, exist_ok=True)
    monkeypatch.setattr(sqlite_mod, "DB_DIR", db_dir)
    monkeypatch.setattr(sqlite_mod, "DB_PATH", os.path.join(db_dir, "test.db"))

    # Isolated FAISS
    faiss_dir = str(tmp_path / "faiss")
    os.makedirs(faiss_dir, exist_ok=True)
    monkeypatch.setattr(faiss_mod, "FAISS_DIR", faiss_dir)

    # Import after monkeypatching
    from bishon_kernel.bishon_server.app import app
    from bishon_kernel.core.local_doc_qa import LocalDocQA

    # Create LocalDocQA with real SQLite/FAISS but mock LLM/Embedding/Rerank
    local_doc_qa = LocalDocQA.__new__(LocalDocQA)
    local_doc_qa.llm = MagicMock()
    # Mock LLM to return a valid answer for empty KB tests
    _mock_answer = MagicMock()
    _mock_answer.llm_output = {"answer": "data: {\"answer\": \"Artificial Intelligence (AI) is a branch of computer science.\"}\n\n"}
    _mock_answer.prompt = "What is AI?"
    _mock_answer.history = [["What is AI?", "Artificial Intelligence (AI) is a branch of computer science."]]
    _mock_done = MagicMock()
    _mock_done.llm_output = {"answer": "data: [DONE]\n\n"}
    _mock_done.prompt = "What is AI?"
    _mock_done.history = [["What is AI?", "Artificial Intelligence (AI) is a branch of computer science."]]
    local_doc_qa.llm.generatorAnswer.return_value = [_mock_answer, _mock_done]

    local_doc_qa.embeddings = MagicMock()
    local_doc_qa.rerank_backend = MagicMock()
    local_doc_qa.rerank_backend.enabled = False
    local_doc_qa.top_k = 5
    local_doc_qa.chunk_size = 800
    local_doc_qa.score_threshold = 1.1
    local_doc_qa.faiss_kbs = []
    local_doc_qa.ocr_engine = None

    from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager
    local_doc_qa.kb_manager = KnowledgeBaseManager()

    # Save and restore app state to avoid SQLite lock conflicts between tests
    original_local_doc_qa = getattr(app.state, 'local_doc_qa', None)
    app.state.local_doc_qa = local_doc_qa

    try:
        transport = ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            yield client
    finally:
        # Wait for any background _safe_insert tasks (queued by upload_files
        # / upload_weblink) to finish before monkeypatch.undo() resets DB_PATH
        # and tmp_path is deleted. Otherwise the bg thread reads a stale
        # DB_PATH and SQLite recreates an empty file → "no such table: File".
        _drain_background_executor()
        app.state.local_doc_qa = original_local_doc_qa
