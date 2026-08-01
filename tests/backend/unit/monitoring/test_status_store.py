"""Tests for ServiceStatusStore — thread-safety, record_outcome, to_api_dict."""
import threading
import time

import pytest

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
    STATUS_UNKNOWN,
    ServiceStatusStore,
)


@pytest.fixture
def store():
    return ServiceStatusStore()


class TestServiceStatusStoreInit:
    def test_all_services_initialized_unknown(self, store):
        all_statuses = store.get_all()
        for name in [SERVICE_LLM, SERVICE_EMBEDDING, SERVICE_RERANK,
                     SERVICE_OCR, SERVICE_FAISS, SERVICE_SQLITE]:
            assert name in all_statuses
            assert all_statuses[name].status == STATUS_UNKNOWN

    def test_start_time_is_recent(self, store):
        assert abs(store.start_time - time.time()) < 2


class TestRecordOutcome:
    def test_record_success(self, store):
        store.record_outcome(SERVICE_LLM, success=True, detail="ollama ok", latency_ms=42.5)
        svc = store.get(SERVICE_LLM)
        assert svc.status == STATUS_HEALTHY
        assert svc.detail == "ollama ok"
        assert svc.latency_ms == 42.5
        assert svc.last_success is not None

    def test_record_failure(self, store):
        store.record_outcome(SERVICE_LLM, success=False, detail="connection refused")
        svc = store.get(SERVICE_LLM)
        assert svc.status == STATUS_UNHEALTHY
        assert svc.detail == "connection refused"
        assert svc.last_success is None

    def test_record_unknown_service(self, store):
        # Should not raise, just log a warning
        store.record_outcome("nonexistent", success=True, detail="test")

    def test_record_updates_last_check(self, store):
        before = time.time()
        store.record_outcome(SERVICE_EMBEDDING, success=True)
        after = time.time()
        svc = store.get(SERVICE_EMBEDDING)
        assert before <= svc.last_check <= after

    def test_success_updates_last_success(self, store):
        store.record_outcome(SERVICE_EMBEDDING, success=False)
        svc = store.get(SERVICE_EMBEDDING)
        assert svc.last_success is None

        store.record_outcome(SERVICE_EMBEDDING, success=True)
        svc = store.get(SERVICE_EMBEDDING)
        assert svc.last_success is not None


class TestRecordProbe:
    def test_record_probe_healthy(self, store):
        store.record_probe(SERVICE_LLM, STATUS_HEALTHY, detail="ollama ok", latency_ms=42.5)
        svc = store.get(SERVICE_LLM)
        assert svc.status == STATUS_HEALTHY
        assert svc.last_success is not None

    def test_record_probe_disabled(self, store):
        store.record_probe(SERVICE_RERANK, STATUS_DISABLED, detail="RERANK_ENABLED=false")
        svc = store.get(SERVICE_RERANK)
        assert svc.status == STATUS_DISABLED
        assert svc.last_success is None

    def test_record_probe_unhealthy(self, store):
        store.record_probe(SERVICE_LLM, STATUS_UNHEALTHY, detail="connection refused")
        svc = store.get(SERVICE_LLM)
        assert svc.status == STATUS_UNHEALTHY
        assert svc.last_success is None

    def test_record_probe_none_detail_preserves_previous(self, store):
        """When detail is None, the previous detail should be preserved."""
        store.record_probe(SERVICE_LLM, STATUS_HEALTHY, detail="ollama ok")
        assert store.get(SERVICE_LLM).detail == "ollama ok"
        store.record_probe(SERVICE_LLM, STATUS_UNHEALTHY, detail=None)
        svc = store.get(SERVICE_LLM)
        assert svc.status == STATUS_UNHEALTHY
        assert svc.detail == "ollama ok"  # Preserved from previous call


class TestQueueStats:
    def test_record_and_get_queue_stats(self, store):
        store.record_queue_stats(pending=3, active=2, max_workers=4)
        stats = store.get_queue_stats()
        assert stats.pending_tasks == 3
        assert stats.active_tasks == 2
        assert stats.max_workers == 4


class TestToApiDict:
    def test_overall_status_ok(self, store):
        store.record_outcome(SERVICE_LLM, success=True)
        store.record_outcome(SERVICE_EMBEDDING, success=True)
        store.record_outcome(SERVICE_RERANK, success=True)
        store.record_outcome(SERVICE_OCR, success=True)
        store.record_outcome(SERVICE_FAISS, success=True)
        store.record_outcome(SERVICE_SQLITE, success=True)
        result = store.to_api_dict(version="2.1.0")
        assert result["status"] == "ok"
        assert result["version"] == "2.1.0"
        assert "uptime_seconds" in result
        assert "services" in result
        assert "queue" in result

    def test_overall_status_degraded(self, store):
        store.record_outcome(SERVICE_LLM, success=True)
        store.record_outcome(SERVICE_EMBEDDING, success=False, detail="unreachable")
        result = store.to_api_dict(version="2.1.0")
        assert result["status"] == "degraded"

    def test_disabled_service_does_not_degrade(self, store):
        # Rerank is disabled but that shouldn't make overall status "degraded"
        store.record_outcome(SERVICE_LLM, success=True)
        store.record_outcome(SERVICE_EMBEDDING, success=True)
        store.record_probe(SERVICE_RERANK, STATUS_DISABLED, detail="disabled")
        store.record_outcome(SERVICE_OCR, success=True)
        store.record_outcome(SERVICE_FAISS, success=True)
        store.record_outcome(SERVICE_SQLITE, success=True)
        result = store.to_api_dict(version="2.1.0")
        assert result["status"] == "ok"
        assert result["services"]["rerank"]["status"] == STATUS_DISABLED


class TestThreadSafety:
    def test_concurrent_record_outcome(self, store):
        """Multiple threads writing simultaneously should not corrupt data."""
        errors = []

        def writer(service_name, count):
            try:
                for i in range(count):
                    store.record_outcome(
                        service_name,
                        success=(i % 2 == 0),
                        detail=f"attempt {i}",
                        latency_ms=float(i),
                    )
            except Exception as e:
                errors.append(e)

        threads = [
            threading.Thread(target=writer, args=(SERVICE_LLM, 100)),
            threading.Thread(target=writer, args=(SERVICE_EMBEDDING, 100)),
            threading.Thread(target=writer, args=(SERVICE_FAISS, 100)),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors
        # All services should have a valid status
        for name in [SERVICE_LLM, SERVICE_EMBEDDING, SERVICE_FAISS]:
            svc = store.get(name)
            assert svc.status in (STATUS_HEALTHY, STATUS_UNHEALTHY)
