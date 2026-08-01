"""Tests for API edge cases."""
import asyncio

import pytest


@pytest.mark.asyncio
class TestHealthEndpoint:
    async def test_health_returns_ok(self, api_client):
        resp = await api_client.get("/api/health")
        assert resp.status_code == 200
        body = resp.json()
        # Enhanced health check returns detailed status
        assert body["status"] in ("ok", "degraded")
        assert "version" in body
        assert "uptime_seconds" in body
        assert "services" in body
        assert "queue" in body

    async def test_health_services_structure(self, api_client):
        resp = await api_client.get("/api/health")
        body = resp.json()
        services = body["services"]
        expected_services = {"llm", "embedding", "rerank", "ocr", "faiss", "sqlite"}
        assert set(services.keys()) == expected_services
        for name, svc in services.items():
            assert "status" in svc
            assert "detail" in svc
            assert svc["status"] in ("healthy", "unhealthy", "unknown", "disabled")

    async def test_health_queue_structure(self, api_client):
        resp = await api_client.get("/api/health")
        body = resp.json()
        queue = body["queue"]
        assert "pending_tasks" in queue
        assert "active_tasks" in queue
        assert "max_workers" in queue


@pytest.mark.asyncio
class TestEmptyBody:
    async def test_new_kb_empty_body(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={})
        assert resp.json()["code"] == 2002

    async def test_list_kbs_empty_body(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/list_knowledge_base", json={})
        assert resp.json()["code"] == 2002

    async def test_delete_kb_empty_body(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/delete_knowledge_base", json={})
        assert resp.json()["code"] == 2002

    async def test_list_files_empty_body(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/list_files", json={})
        assert resp.json()["code"] == 2002

    async def test_chat_empty_body(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/local_doc_chat", json={})
        assert resp.json()["code"] == 2002


@pytest.mark.asyncio
class TestLongUserId:
    async def test_long_valid_user_id(self, api_client):
        long_id = "a" * 256
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": long_id, "kb_name": "LongID"
        })
        assert resp.json()["code"] == 200


@pytest.mark.asyncio
class TestConcurrentKBCreate:
    async def test_concurrent_creates(self, api_client):
        tasks = [
            api_client.post("/api/local_doc_qa/new_knowledge_base", json={
                "user_id": "concurrent_user", "kb_name": f"ConcurrentKB{i}"
            })
            for i in range(5)
        ]
        responses = await asyncio.gather(*tasks)
        codes = [r.json()["code"] for r in responses]
        assert all(c == 200 for c in codes)

        list_resp = await api_client.post("/api/local_doc_qa/list_knowledge_base", json={
            "user_id": "concurrent_user"
        })
        assert len(list_resp.json()["data"]) == 5


@pytest.mark.asyncio
class TestFilenameSpecialChars:
    async def test_chinese_filename(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "testuser", "kb_name": "SpecialName"
        })
        kb_id = resp.json()["data"]["kb_id"]
        upload_resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("测试文件.txt", b"Chinese filename content", "text/plain")},
        )
        assert upload_resp.json()["code"] == 200

    async def test_space_in_filename(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "testuser", "kb_name": "SpaceTest"
        })
        kb_id = resp.json()["data"]["kb_id"]
        upload_resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("file with spaces.txt", b"space filename", "text/plain")},
        )
        assert upload_resp.json()["code"] == 200
