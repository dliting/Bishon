"""Tests for HealthChecker — periodic loop and probe orchestration."""
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from bishon_kernel.monitoring.health_checker import CHECK_INTERVAL_SECONDS, HealthChecker
from bishon_kernel.monitoring.status_store import SERVICE_LLM, STATUS_HEALTHY, ServiceStatusStore
from bishon_kernel.monitoring.tracked_executor import TrackedExecutor


@pytest.fixture
def store():
    return ServiceStatusStore()


@pytest.fixture
def executor():
    ex = TrackedExecutor(max_workers=2)
    yield ex
    ex.shutdown(wait=False)


@pytest.fixture
def mock_local_doc_qa():
    qa = MagicMock()
    qa.ocr_engine = None
    qa.faiss_kbs = []
    qa.rerank_backend = MagicMock()
    qa.rerank_backend.enabled = False
    qa.kb_manager = MagicMock()
    qa.kb_manager.conn = MagicMock()
    qa.kb_manager.conn.execute.return_value.fetchone.return_value = (1,)
    qa.kb_manager.db_path = "/tmp/test.db"
    return qa


class TestHealthCheckerInterval:
    def test_check_interval_is_60_seconds(self):
        assert CHECK_INTERVAL_SECONDS == 60


class TestHealthCheckerStartStop:
    @pytest.mark.asyncio
    async def test_start_and_stop(self, mock_local_doc_qa, store, executor):
        checker = HealthChecker(mock_local_doc_qa, store, executor)
        await checker.start()
        assert checker._task is not None
        assert checker._probe_executor is not None
        await checker.stop()
        assert checker._task is None
        checker.shutdown()

    @pytest.mark.asyncio
    async def test_stop_without_start(self, mock_local_doc_qa, store, executor):
        checker = HealthChecker(mock_local_doc_qa, store, executor)
        # Should not raise
        await checker.stop()
        checker.shutdown()


class TestHealthCheckerProbes:
    @pytest.mark.asyncio
    async def test_run_probes_updates_store(self, mock_local_doc_qa, store, executor):
        checker = HealthChecker(mock_local_doc_qa, store, executor)

        # Mock the probes to return quickly
        with patch("bishon_kernel.monitoring.health_checker.ALL_PROBES") as mock_probes:
            mock_probes.items.return_value = [
                (SERVICE_LLM, MagicMock(return_value=(STATUS_HEALTHY, "test ok", 10.0))),
            ]
            await checker._run_probes()

        svc = store.get(SERVICE_LLM)
        assert svc.status == STATUS_HEALTHY
        assert svc.detail == "test ok"

    @pytest.mark.asyncio
    async def test_run_probes_handles_exception(self, mock_local_doc_qa, store, executor):
        checker = HealthChecker(mock_local_doc_qa, store, executor)

        def failing_probe(_qa):
            raise RuntimeError("probe crashed")

        with patch("bishon_kernel.monitoring.health_checker.ALL_PROBES") as mock_probes:
            mock_probes.items.return_value = [
                (SERVICE_LLM, failing_probe),
            ]
            await checker._run_probes()

        svc = store.get(SERVICE_LLM)
        assert svc.status == "unhealthy"
        assert "probe error" in svc.detail

    @pytest.mark.asyncio
    async def test_run_probes_records_queue_stats(self, mock_local_doc_qa, store, executor):
        checker = HealthChecker(mock_local_doc_qa, store, executor)

        with patch("bishon_kernel.monitoring.health_checker.ALL_PROBES") as mock_probes:
            mock_probes.items.return_value = []
            await checker._run_probes()

        stats = store.get_queue_stats()
        assert stats.max_workers == 2
