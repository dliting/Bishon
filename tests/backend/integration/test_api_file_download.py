"""Tests for the file download / traceability API — upload-to-download round trip."""
import pytest


async def _create_kb(api_client, user_id="testuser", kb_name="DownloadTest"):
    resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
        "user_id": user_id, "kb_name": kb_name
    })
    return resp.json()["data"]["kb_id"]


async def _upload_file(api_client, kb_id, filename, content, user_id="testuser"):
    resp = await api_client.post(
        "/api/local_doc_qa/upload_files",
        data={"user_id": user_id, "kb_id": kb_id, "mode": "soft"},
        files={"files": (filename, content, "application/octet-stream")},
    )
    data = resp.json()
    assert data["code"] == 200
    return data["data"][0]["file_id"]


@pytest.mark.asyncio
class TestFileDownload:
    async def test_download_uploaded_file(self, api_client):
        """After uploading, downloading by file_id returns the same content with Content-Disposition attachment."""
        content = b"traceability integration test content"
        kb_id   = await _create_kb(api_client)
        file_id = await _upload_file(api_client, kb_id, "trace_test.txt", content)

        resp = await api_client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 200
        assert resp.content == content
        assert "content-disposition" in resp.headers
        assert resp.headers["content-disposition"].startswith("attachment")
        assert "trace_test.txt" in resp.headers["content-disposition"]

    async def test_download_nonexistent_file(self, api_client):
        """A non-existent file_id returns 404."""
        resp = await api_client.get("/api/local_doc_qa/download_file/abcdef1234567890abcdef1234567890")
        assert resp.status_code == 404
        assert resp.json()["code"] == 2004

    async def test_download_url_type_redirects(self, api_client):
        """A URL-type source document returns a 302 redirect."""
        url = "https://example.com/docs/page.html"
        kb_id = await _create_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/upload_weblink", json={
            "user_id": "testuser", "kb_id": kb_id, "url": url,
        })
        file_id = resp.json()["data"][0]["file_id"]

        resp = await api_client.get(
            f"/api/local_doc_qa/download_file/{file_id}",
            follow_redirects=False,
        )
        assert resp.status_code == 302
        assert resp.headers["location"] == url

    async def test_download_deleted_file(self, api_client):
        """After deleting a file via the delete_files API, download returns 404."""
        content = b"to be deleted"
        kb_id   = await _create_kb(api_client)
        file_id = await _upload_file(api_client, kb_id, "deleted_test.txt", content)

        # Confirm file is downloadable before deletion
        resp = await api_client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 200

        # Delete the file via API
        resp = await api_client.post("/api/local_doc_qa/delete_files", json={
            "user_id": "testuser", "kb_id": kb_id, "file_ids": [file_id],
        })
        assert resp.json()["code"] == 200

        # Download should now return 404
        resp = await api_client.get(f"/api/local_doc_qa/download_file/{file_id}")
        assert resp.status_code == 404
        assert resp.json()["code"] == 2004
