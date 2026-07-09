"""Tests for file upload / delete / status APIs."""
import pytest


async def _create_kb(api_client, user_id="testuser", kb_name="UploadTest"):
    resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
        "user_id": user_id, "kb_name": kb_name
    })
    return resp.json()["data"]["kb_id"]


@pytest.mark.asyncio
class TestUploadFiles:
    async def test_upload_single_txt(self, api_client):
        kb_id = await _create_kb(api_client)
        resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "soft"},
            files={"files": ("test.txt", b"Hello world content", "text/plain")},
        )
        data = resp.json()
        assert data["code"] == 200
        assert len(data["data"]) == 1
        assert data["data"][0]["file_name"] == "test.txt"
        assert "file_id" in data["data"][0]

    async def test_upload_multiple_files(self, api_client):
        kb_id = await _create_kb(api_client)
        resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files=[
                ("files", ("a.txt", b"content a", "text/plain")),
                ("files", ("b.txt", b"content b", "text/plain")),
            ],
        )
        data = resp.json()
        assert data["code"] == 200
        assert len(data["data"]) == 2

    async def test_upload_soft_duplicate_rejected(self, api_client):
        kb_id = await _create_kb(api_client)
        await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "soft"},
            files={"files": ("dup.txt", b"first", "text/plain")},
        )
        resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "soft"},
            files={"files": ("dup.txt", b"second", "text/plain")},
        )
        assert "warning" in resp.json()["msg"]

    async def test_upload_strong_duplicate_allowed(self, api_client):
        kb_id = await _create_kb(api_client)
        await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("dup.txt", b"first", "text/plain")},
        )
        resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("dup.txt", b"second", "text/plain")},
        )
        assert resp.json()["code"] == 200

    async def test_upload_invalid_kb(self, api_client):
        resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": "KB_NONEXISTENT", "mode": "soft"},
            files={"files": ("test.txt", b"hello", "text/plain")},
        )
        assert resp.json()["code"] == 2001


@pytest.mark.asyncio
class TestUploadWeblink:
    async def test_upload_url(self, api_client):
        kb_id = await _create_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/upload_weblink", json={
            "user_id": "testuser", "kb_id": kb_id, "url": "https://example.com"
        })
        data = resp.json()
        assert data["code"] == 200
        assert data["data"][0]["file_name"] == "https://example.com"

    async def test_upload_url_empty(self, api_client):
        kb_id = await _create_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/upload_weblink", json={
            "user_id": "testuser", "kb_id": kb_id, "url": ""
        })
        assert resp.json()["code"] == 2002

    async def test_upload_url_invalid_kb(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/upload_weblink", json={
            "user_id": "testuser", "kb_id": "KB_NONEXISTENT", "url": "https://example.com"
        })
        assert resp.json()["code"] == 2001

    async def test_upload_url_soft_duplicate(self, api_client):
        kb_id = await _create_kb(api_client)
        await api_client.post("/api/local_doc_qa/upload_weblink", json={
            "user_id": "testuser", "kb_id": kb_id, "url": "https://example.com"
        })
        resp = await api_client.post("/api/local_doc_qa/upload_weblink", json={
            "user_id": "testuser", "kb_id": kb_id, "url": "https://example.com", "mode": "soft"
        })
        assert "warning" in resp.json()["msg"]


@pytest.mark.asyncio
class TestListFiles:
    async def test_list_files_after_upload(self, api_client):
        kb_id = await _create_kb(api_client)
        await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("listed.txt", b"content", "text/plain")},
        )
        resp = await api_client.post("/api/local_doc_qa/list_files", json={
            "user_id": "testuser", "kb_id": kb_id
        })
        data = resp.json()
        assert data["code"] == 200
        assert "total" in data["data"]
        assert "details" in data["data"]
        assert len(data["data"]["details"]) >= 1

    async def test_list_files_status_fields(self, api_client):
        kb_id = await _create_kb(api_client)
        await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("status_test.txt", b"x", "text/plain")},
        )
        resp = await api_client.post("/api/local_doc_qa/list_files", json={
            "user_id": "testuser", "kb_id": kb_id
        })
        detail = resp.json()["data"]["details"][0]
        assert "file_id" in detail
        assert "file_name" in detail
        assert "status" in detail
        assert "bytes" in detail


@pytest.mark.asyncio
class TestDeleteFiles:
    async def test_delete_single_file(self, api_client):
        kb_id = await _create_kb(api_client)
        upload_resp = await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("del.txt", b"delete me", "text/plain")},
        )
        file_id = upload_resp.json()["data"][0]["file_id"]
        resp = await api_client.post("/api/local_doc_qa/delete_files", json={
            "user_id": "testuser", "kb_id": kb_id, "file_ids": [file_id]
        })
        assert resp.json()["code"] == 200

    async def test_delete_empty_file_ids(self, api_client):
        kb_id = await _create_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/delete_files", json={
            "user_id": "testuser", "kb_id": kb_id, "file_ids": []
        })
        assert resp.json()["code"] == 2004


@pytest.mark.asyncio
class TestGetTotalStatus:
    async def test_status_counts(self, api_client):
        kb_id = await _create_kb(api_client)
        await api_client.post(
            "/api/local_doc_qa/upload_files",
            data={"user_id": "testuser", "kb_id": kb_id, "mode": "strong"},
            files={"files": ("stat.txt", b"status check", "text/plain")},
        )
        resp = await api_client.post("/api/local_doc_qa/get_total_status", json={
            "user_id": "testuser"
        })
        data = resp.json()
        assert data["code"] == 200
        assert "status" in data


@pytest.mark.asyncio
class TestCleanFilesByStatus:
    async def test_clean_gray_files(self, api_client):
        kb_id = await _create_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/clean_files_by_status", json={
            "user_id": "testuser", "kb_ids": [kb_id], "status": "gray"
        })
        assert resp.json()["code"] == 200

    async def test_clean_all_kbs_when_no_kb_ids(self, api_client):
        await _create_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/clean_files_by_status", json={
            "user_id": "testuser", "status": "gray"
        })
        assert resp.json()["code"] == 200
