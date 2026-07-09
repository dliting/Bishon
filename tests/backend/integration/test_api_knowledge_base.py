"""Tests for knowledge base CRUD APIs."""
import pytest


@pytest.mark.asyncio
class TestKnowledgeBaseAPI:
    async def test_create_kb(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "testuser", "kb_name": "Test KB"
        })
        data = resp.json()
        assert data["code"] == 200
        assert "kb_id" in data["data"]
        assert data["data"]["kb_name"] == "Test KB"

    async def test_create_kb_missing_user_id(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "kb_name": "Test"
        })
        assert resp.json()["code"] == 2002

    async def test_create_kb_invalid_user_id(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "123abc", "kb_name": "Test"
        })
        assert resp.json()["code"] == 2005

    async def test_list_kbs(self, api_client):
        await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "testuser", "kb_name": "KB1"
        })
        resp = await api_client.post("/api/local_doc_qa/list_knowledge_base", json={
            "user_id": "testuser"
        })
        data = resp.json()
        assert data["code"] == 200
        assert len(data["data"]) >= 1

    async def test_list_kbs_empty(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/list_knowledge_base", json={
            "user_id": "empty_user"
        })
        data = resp.json()
        assert data["code"] == 200
        assert data["data"] == []

    async def test_rename_kb(self, api_client):
        create_resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "testuser", "kb_name": "Old"
        })
        kb_id = create_resp.json()["data"]["kb_id"]

        resp = await api_client.post("/api/local_doc_qa/rename_knowledge_base", json={
            "user_id": "testuser", "kb_id": kb_id, "new_kb_name": "New"
        })
        assert resp.json()["code"] == 200

        list_resp = await api_client.post("/api/local_doc_qa/list_knowledge_base", json={
            "user_id": "testuser"
        })
        names = [kb["kb_name"] for kb in list_resp.json()["data"]]
        assert "New" in names

    async def test_rename_nonexistent_kb(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/rename_knowledge_base", json={
            "user_id": "testuser", "kb_id": "KB_NONEXISTENT", "new_kb_name": "X"
        })
        assert resp.json()["code"] == 2003

    async def test_delete_kb(self, api_client):
        create_resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
            "user_id": "testuser", "kb_name": "To Delete"
        })
        kb_id = create_resp.json()["data"]["kb_id"]

        resp = await api_client.post("/api/local_doc_qa/delete_knowledge_base", json={
            "user_id": "testuser", "kb_ids": [kb_id]
        })
        assert resp.json()["code"] == 200

    async def test_delete_nonexistent_kb(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/delete_knowledge_base", json={
            "user_id": "testuser", "kb_ids": ["KB_NONEXISTENT"]
        })
        assert resp.json()["code"] == 2003

    async def test_docs_endpoint(self, api_client):
        resp = await api_client.get("/api/docs")
        assert resp.status_code == 200
        assert "Bishon V2" in resp.text
