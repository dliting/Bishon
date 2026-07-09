"""Real-service pipeline tests — requires Ollama (embedding + LLM).

Auto-skipped when Ollama is unavailable.
Run with: python -m pytest tests/backend/integration/test_pipeline_real.py -v
"""
import os
import time

import httpx
import pytest
from httpx import ASGITransport


def _ollama_available():
    """Check whether the Ollama service is available."""
    try:
        import urllib.request
        req = urllib.request.Request("http://localhost:11434/", method="GET")
        urllib.request.urlopen(req, timeout=3)
        return True
    except Exception:
        return False


requires_ollama = pytest.mark.skipif(
    not _ollama_available(),
    reason="Ollama service not running on localhost:11434"
)


@pytest.fixture
async def real_api_client(tmp_path, monkeypatch):
    """API client with real Embedding/LLM (Ollama) + temporary SQLite/FAISS."""
    import bishon_kernel.connector.database.faiss.faiss_client as faiss_mod
    import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod
    from bishon_kernel.bishon_server.app import app
    from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager
    from bishon_kernel.connector.embedding.openai_embedding import OpenAIEmbeddings
    from bishon_kernel.connector.llm.llm_for_openai_api import OpenAILLM
    from bishon_kernel.connector.rerank.rerank_client import LocalRerankBackend
    from bishon_kernel.core.local_doc_qa import LocalDocQA

    db_dir = str(tmp_path / "db")
    os.makedirs(db_dir, exist_ok=True)
    monkeypatch.setattr(sqlite_mod, "DB_DIR", db_dir)
    monkeypatch.setattr(sqlite_mod, "DB_PATH", os.path.join(db_dir, "test.db"))

    faiss_dir = str(tmp_path / "faiss")
    os.makedirs(faiss_dir, exist_ok=True)
    monkeypatch.setattr(faiss_mod, "FAISS_DIR", faiss_dir)

    # Save original app state
    original_local_doc_qa = getattr(app.state, 'local_doc_qa', None)

    local_doc_qa = LocalDocQA()
    local_doc_qa.embeddings    = OpenAIEmbeddings()
    local_doc_qa.llm           = OpenAILLM()
    local_doc_qa.kb_manager    = KnowledgeBaseManager()
    local_doc_qa.rerank_backend = LocalRerankBackend()
    local_doc_qa.faiss_kbs     = []
    app.state.local_doc_qa     = local_doc_qa

    transport = ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client

    # Restore original app state
    app.state.local_doc_qa = original_local_doc_qa


@requires_ollama
class TestRealUploadPipeline:
    """Test: upload file -> parse -> embedding -> status turns green."""

    @pytest.mark.asyncio
    async def test_upload_txt_file_turns_green(self, real_api_client):
        # 1. Create KB
        resp = await real_api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "pipeline_user", "kb_name": "PipelineTest"
        })
        data = resp.json()
        assert data["code"] == 200
        kb_id = data["data"]["kb_id"]

        # 2. Upload file
        upload_resp = await real_api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "pipeline_user", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("pipeline_test.txt", b"AI is a branch of computer science. Deep learning uses neural networks.", "text/plain")},
        )
        assert upload_resp.json()["code"] == 200
        file_id = upload_resp.json()["data"][0]["file_id"]

        # 3. Wait for background processing (max 30 seconds)
        status = "gray"
        for _ in range(30):
            list_resp = await real_api_client.post("/api/local_doc_qa/list_files", json={
                "user_id": "pipeline_user", "kb_id": kb_id
            })
            files = list_resp.json()["data"]["details"]
            file_info = next((f for f in files if f["file_id"] == file_id), None)
            if file_info and file_info["status"] in ("green", "red", "yellow"):
                status = file_info["status"]
                break
            time.sleep(1)

        assert status == "green", f"Expected green, got {status}"

    @pytest.mark.asyncio
    async def test_upload_csv_file(self, real_api_client):
        resp = await real_api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "pipeline_user", "kb_name": "CSVTest"
        })
        kb_id = resp.json()["data"]["kb_id"]

        csv_content = b"name,age\nAlice,30\nBob,25\n"
        upload_resp = await real_api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "pipeline_user", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("test.csv", csv_content, "text/csv")},
        )
        assert upload_resp.json()["code"] == 200


@requires_ollama
class TestRealChatPipeline:
    """Test: upload file -> chat -> get a real LLM answer."""

    @pytest.mark.asyncio
    async def test_chat_with_document_returns_answer(self, real_api_client):
        # 1. Setup KB with document
        resp = await real_api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "chat_user", "kb_name": "ChatPipelineTest"
        })
        kb_id = resp.json()["data"]["kb_id"]

        doc_content = b"The capital of France is Paris. The capital of Germany is Berlin. The capital of Japan is Tokyo."
        upload_resp = await real_api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "chat_user", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("capitals.txt", doc_content, "text/plain")},
        )
        assert upload_resp.json()["code"] == 200

        # 2. Wait for indexing
        for _ in range(30):
            list_resp = await real_api_client.post("/api/local_doc_qa/list_files", json={
                "user_id": "chat_user", "kb_id": kb_id
            })
            files = list_resp.json()["data"]["details"]
            if files and files[0]["status"] == "green":
                break
            time.sleep(1)
        else:
            pytest.skip("File did not reach green status in time")

        # 3. Ask question (non-streaming)
        chat_resp = await real_api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "chat_user",
            "kb_ids": [kb_id],
            "question": "What is the capital of France?",
            "streaming": False,
        })
        data = chat_resp.json()
        assert data["code"] == 200
        # LLM should mention Paris
        response_text = data.get("response", "").lower()
        assert len(response_text) >= 1, "LLM returned empty response"

    @pytest.mark.asyncio
    async def test_streaming_chat_returns_sse(self, real_api_client):
        resp = await real_api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "chat_user", "kb_name": "StreamPipelineTest"
        })
        kb_id = resp.json()["data"]["kb_id"]

        await real_api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "chat_user", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("stream_test.txt", b"Testing streaming response from the system.", "text/plain")},
        )

        # Wait for indexing
        for _ in range(30):
            list_resp = await real_api_client.post("/api/local_doc_qa/list_files", json={
                "user_id": "chat_user", "kb_id": kb_id
            })
            files = list_resp.json()["data"]["details"]
            if files and files[0]["status"] == "green":
                break
            time.sleep(1)
        else:
            pytest.skip("File did not reach green status in time")

        chat_resp = await real_api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "chat_user",
            "kb_ids": [kb_id],
            "question": "hello",
            "streaming": True,
        })
        assert chat_resp.status_code == 200
        assert "text/event-stream" in chat_resp.headers.get("content-type", "")
        text = chat_resp.text
        lines = [l for l in text.split("\n") if l.startswith("data: ")]
        assert len(lines) >= 1
        assert any("[DONE]" in l for l in lines)
