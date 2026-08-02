"""Tests for service probes — mock network calls, verify probe results."""
import sqlite3

from unittest.mock import MagicMock, patch

import pytest

from bishon_kernel.monitoring.status_store import STATUS_DISABLED, STATUS_HEALTHY, STATUS_UNHEALTHY
from bishon_kernel.monitoring.service_probes import (
    ALL_PROBES,
    probe_embedding,
    probe_faiss,
    probe_gpu,
    probe_llm,
    probe_ocr,
    probe_rerank,
    probe_sqlite,
)


@pytest.fixture
def mock_local_doc_qa():
    qa = MagicMock()
    qa.ocr_engine = MagicMock()
    qa.faiss_kbs = [MagicMock()]
    qa.rerank_backend = MagicMock()
    qa.rerank_backend.enabled = True
    qa.rerank_backend.model_type = "generative"
    qa.kb_manager = MagicMock()
    qa.kb_manager.conn = MagicMock()
    qa.kb_manager.conn.execute.return_value.fetchone.return_value = (1,)
    qa.kb_manager.db_path = "/tmp/test.db"
    return qa


class TestProbeLlm:
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.LLM_PROVIDER", "ollama")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_BASE", "http://localhost:11434/v1")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_MODEL_NAME", "qwen3:8b")
    @patch("bishon_kernel.monitoring.service_probes.httpx.Client")
    def test_ollama_healthy(self, mock_client_cls, mock_local_doc_qa):
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.raise_for_status = MagicMock()
        mock_client = MagicMock()
        mock_client.get.return_value = mock_resp
        mock_client.__enter__ = MagicMock(return_value=mock_client)
        mock_client.__exit__ = MagicMock(return_value=False)
        mock_client_cls.return_value = mock_client

        success, detail, latency = probe_llm(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "ollama" in detail.lower()
        assert latency >= 0

    @patch("bishon_kernel.connector.llm.llm_for_openai_api.LLM_PROVIDER", "ollama")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_BASE", "http://localhost:11434/v1")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_MODEL_NAME", "qwen3:8b")
    @patch("bishon_kernel.monitoring.service_probes.httpx.Client")
    def test_ollama_unhealthy(self, mock_client_cls, mock_local_doc_qa):
        mock_client = MagicMock()
        mock_client.get.side_effect = Exception("Connection refused")
        mock_client.__enter__ = MagicMock(return_value=mock_client)
        mock_client.__exit__ = MagicMock(return_value=False)
        mock_client_cls.return_value = mock_client

        success, detail, latency = probe_llm(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "Connection refused" in detail

    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_KEY", "test-key-123")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.LLM_PROVIDER", "openai")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_BASE", "https://api.openai.com/v1")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_MODEL_NAME", "gpt-4")
    @patch("bishon_kernel.monitoring.service_probes.httpx.Client")
    def test_openai_healthy(self, mock_client_cls, mock_local_doc_qa):
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.raise_for_status = MagicMock()
        mock_client = MagicMock()
        mock_client.get.return_value = mock_resp
        mock_client.__enter__ = MagicMock(return_value=mock_client)
        mock_client.__exit__ = MagicMock(return_value=False)
        mock_client_cls.return_value = mock_client

        success, detail, latency = probe_llm(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "openai" in detail.lower()
        assert latency >= 0
        # Non-ollama providers must send the API key as a Bearer token
        _, kwargs = mock_client.get.call_args
        assert kwargs.get("headers", {}).get("Authorization") == "Bearer test-key-123"

    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_KEY", None)
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.LLM_PROVIDER", "openai")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_BASE", "https://api.openai.com/v1")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_MODEL_NAME", "gpt-4")
    @patch("bishon_kernel.monitoring.service_probes.httpx.Client")
    def test_openai_sends_no_auth_without_key(self, mock_client_cls, mock_local_doc_qa):
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.raise_for_status = MagicMock()
        mock_client = MagicMock()
        mock_client.get.return_value = mock_resp
        mock_client.__enter__ = MagicMock(return_value=mock_client)
        mock_client.__exit__ = MagicMock(return_value=False)
        mock_client_cls.return_value = mock_client

        success, detail, latency = probe_llm(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        _, kwargs = mock_client.get.call_args
        assert "Authorization" not in kwargs.get("headers", {})

    @patch("bishon_kernel.connector.llm.llm_for_openai_api.LLM_PROVIDER", "openai")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_BASE", "")
    @patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_MODEL_NAME", "gpt-4")
    def test_no_api_base_url(self, mock_local_doc_qa):
        success, detail, latency = probe_llm(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "no API base URL" in detail


class TestProbeEmbedding:
    @patch("bishon_kernel.connector.embedding.openai_embedding.BASE_URL", "http://localhost:11434/v1")
    @patch("bishon_kernel.connector.embedding.openai_embedding.EMBEDDING_MODEL_NAME", "qwen3-embedding:0.6b")
    @patch("bishon_kernel.monitoring.service_probes.httpx.Client")
    def test_embedding_healthy(self, mock_client_cls, mock_local_doc_qa):
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.raise_for_status = MagicMock()
        mock_client = MagicMock()
        mock_client.get.return_value = mock_resp
        mock_client.__enter__ = MagicMock(return_value=mock_client)
        mock_client.__exit__ = MagicMock(return_value=False)
        mock_client_cls.return_value = mock_client

        success, detail, latency = probe_embedding(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "qwen3-embedding" in detail

    @patch("bishon_kernel.connector.embedding.openai_embedding.BASE_URL", "http://localhost:11434/v1")
    @patch("bishon_kernel.connector.embedding.openai_embedding.EMBEDDING_MODEL_NAME", "qwen3-embedding:0.6b")
    @patch("bishon_kernel.monitoring.service_probes.httpx.Client")
    def test_embedding_unhealthy(self, mock_client_cls, mock_local_doc_qa):
        mock_client = MagicMock()
        mock_client.get.side_effect = Exception("Connection refused")
        mock_client.__enter__ = MagicMock(return_value=mock_client)
        mock_client.__exit__ = MagicMock(return_value=False)
        mock_client_cls.return_value = mock_client

        success, detail, latency = probe_embedding(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "Connection refused" in detail

    @patch("bishon_kernel.connector.embedding.openai_embedding.BASE_URL", "")
    @patch("bishon_kernel.connector.embedding.openai_embedding.EMBEDDING_MODEL_NAME", "qwen3-embedding:0.6b")
    def test_embedding_no_base_url(self, mock_local_doc_qa):
        success, detail, latency = probe_embedding(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "no embedding API base URL" in detail


class TestProbeRerank:
    @patch("bishon_kernel.connector.rerank.rerank_client.RERANK_ENABLED", False)
    def test_rerank_disabled(self, mock_local_doc_qa):
        success, detail, latency = probe_rerank(mock_local_doc_qa)
        assert success == STATUS_DISABLED
        assert "disabled" in detail

    @patch("bishon_kernel.connector.rerank.rerank_client.RERANK_ENABLED", True)
    @patch("bishon_kernel.connector.rerank.rerank_client.RERANK_MODEL_PATH", "/nonexistent/path")
    def test_rerank_model_not_found(self, mock_local_doc_qa):
        success, detail, latency = probe_rerank(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "not found" in detail


class TestProbeOcr:
    @patch("bishon_kernel.utils.gpu_utils.can_use_ocr_gpu", return_value=True)
    def test_ocr_available(self, mock_gpu, mock_local_doc_qa):
        success, detail, latency = probe_ocr(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "PaddleOCR" in detail

    def test_ocr_not_available(self, mock_local_doc_qa):
        mock_local_doc_qa.ocr_engine = None
        success, detail, latency = probe_ocr(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "not initialized" in detail


class TestProbeFaiss:
    def test_faiss_with_collections(self, mock_local_doc_qa):
        success, detail, latency = probe_faiss(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "1 collection" in detail

    def test_faiss_empty(self, mock_local_doc_qa):
        mock_local_doc_qa.faiss_kbs = []
        success, detail, latency = probe_faiss(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "0 collections" in detail


class TestProbeSqlite:
    @patch("bishon_kernel.connector.database.sqlite.sqlite_client.DB_PATH", "/tmp/test.db")
    @patch("sqlite3.connect")
    def test_sqlite_healthy(self, mock_connect, mock_local_doc_qa):
        mock_conn = MagicMock()
        mock_conn.execute.return_value.fetchone.return_value = (1,)
        mock_connect.return_value = mock_conn
        success, detail, latency = probe_sqlite(mock_local_doc_qa)
        assert success == STATUS_HEALTHY
        assert "/tmp/test.db" in detail

    def test_sqlite_no_manager(self, mock_local_doc_qa):
        mock_local_doc_qa.kb_manager = None
        success, detail, latency = probe_sqlite(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "KnowledgeBaseManager" in detail

    @patch("bishon_kernel.connector.database.sqlite.sqlite_client.DB_PATH", "/tmp/test.db")
    @patch("sqlite3.connect")
    def test_sqlite_query_error(self, mock_connect, mock_local_doc_qa):
        mock_connect.side_effect = Exception("disk error")
        success, detail, latency = probe_sqlite(mock_local_doc_qa)
        assert success == STATUS_UNHEALTHY
        assert "disk error" in detail


class TestAllProbesRegistry:
    def test_all_services_have_probes(self):
        expected = {"llm", "embedding", "rerank", "ocr", "faiss", "sqlite", "gpu"}
        assert set(ALL_PROBES.keys()) == expected

    def test_all_probes_are_callable(self):
        for name, probe_fn in ALL_PROBES.items():
            assert callable(probe_fn), f"Probe for {name} is not callable"


class TestProbeGpu:
    """GPU probe — surfaces CUDA availability (or lack of) for torch + paddle.

    See docs/wsl-docker-gpu-pitfall.md for why this matters.
    """

    def test_gpu_healthy_when_torch_cuda_available(self, mock_local_doc_qa):
        """torch sees CUDA → healthy, detail shows device name + CUDA version."""
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.return_value = True
        fake_torch.cuda.get_device_name.return_value = "RTX 3080"
        fake_torch.version.cuda = "12.6"
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.return_value = 1

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            status, detail, latency = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_HEALTHY
        assert "RTX 3080" in detail
        assert "12.6" in detail
        assert "paddle cuda=ok" in detail
        assert latency >= 0

    def test_gpu_healthy_when_only_paddle_cuda(self, mock_local_doc_qa):
        """torch missing CUDA but paddle can use GPU at runtime → still healthy."""
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.return_value = False
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.return_value = 1

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            status, detail, latency = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_HEALTHY
        assert "paddle cuda=ok" in detail

    def test_gpu_unhealthy_when_no_usable_device(self, mock_local_doc_qa):
        """Both frameworks report no usable CUDA device → unhealthy.

        Covers: paddle built without CUDA, GPU driver unreachable, or WSL2
        missing /usr/lib/wsl mount. device_count() returns 0 in all three
        cases — that's why the probe uses it instead of the misleading
        is_compiled_with_cuda() (which returns True even when the GPU is
        unreachable at runtime).
        """
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.return_value = False
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.return_value = 0

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            status, detail, _ = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_UNHEALTHY
        assert "both unavailable" in detail

    def test_gpu_unhealthy_when_torch_cuda_raises(self, mock_local_doc_qa):
        """torch.cuda.is_available() raising (e.g., cuInit returns 500) is
        caught — probe falls through to paddle and reports unhealthy only
        if paddle also fails. No 500 to the API caller.
        """
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.side_effect = RuntimeError("Error 500: named symbol not found")
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.return_value = 0

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            status, detail, _ = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_UNHEALTHY
        assert "both unavailable" in detail

    def test_gpu_unhealthy_when_paddle_cuda_raises(self, mock_local_doc_qa):
        """paddle.device.cuda.device_count() raising is caught too."""
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.return_value = False
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.side_effect = RuntimeError("cuInit failed")

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            status, detail, _ = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_UNHEALTHY
        assert "both unavailable" in detail

    def test_gpu_unhealthy_includes_wsl_hint_on_wsl(self, mock_local_doc_qa):
        """On WSL the detail mentions the bind-mount pitfall."""
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.return_value = False
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.return_value = 0

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            with patch(
                "bishon_kernel.monitoring.service_probes._is_wsl",
                return_value=True,
            ):
                status, detail, _ = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_UNHEALTHY
        assert "/usr/lib/wsl" in detail
        assert "wsl-docker-gpu-pitfall.md" in detail

    def test_gpu_unhealthy_no_wsl_hint_on_native_linux(self, mock_local_doc_qa):
        """Native Linux without WSL → no bind-mount hint in detail."""
        fake_torch = MagicMock()
        fake_torch.cuda.is_available.return_value = False
        fake_paddle = MagicMock()
        fake_paddle.device.cuda.device_count.return_value = 0

        with patch.dict("sys.modules", {"torch": fake_torch, "paddle": fake_paddle}):
            with patch(
                "bishon_kernel.monitoring.service_probes._is_wsl",
                return_value=False,
            ):
                status, detail, _ = probe_gpu(mock_local_doc_qa)

        assert status == STATUS_UNHEALTHY
        assert "/usr/lib/wsl" not in detail

