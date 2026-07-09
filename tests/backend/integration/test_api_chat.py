"""Tests for the chat API (streaming SSE + non-streaming)."""
import json

import pytest


async def _create_empty_kb(api_client, user_id="testuser"):
    resp = await api_client.post("/api/local_doc_qa/new_knowledge_base", json={
        "user_id": user_id, "kb_name": "ChatEmpty"
    })
    return resp.json()["data"]["kb_id"]


@pytest.mark.asyncio
class TestChatNonStreaming:
    async def test_empty_kb_still_answers(self, api_client):
        kb_id = await _create_empty_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "testuser", "kb_ids": [kb_id],
            "question": "What is AI?", "streaming": False
        })
        data = resp.json()
        assert data["code"] == 200
        # Empty KB: LLM should still answer using its own knowledge
        assert isinstance(data.get("response", ""), str)

    async def test_missing_question(self, api_client):
        kb_id = await _create_empty_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "testuser", "kb_ids": [kb_id], "streaming": False
        })
        assert resp.json()["code"] == 2002

    async def test_invalid_kb_ids(self, api_client):
        resp = await api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "testuser", "kb_ids": ["KB_NONEXISTENT"],
            "question": "test", "streaming": False
        })
        assert resp.json()["code"] == 2003


@pytest.mark.asyncio
class TestChatStreaming:
    async def test_streaming_empty_kb(self, api_client):
        kb_id = await _create_empty_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "testuser", "kb_ids": [kb_id],
            "question": "test", "streaming": True
        })
        assert resp.status_code == 200
        assert "text/event-stream" in resp.headers.get("content-type", "")
        text = resp.text
        lines = [l for l in text.split("\n") if l.startswith("data: ")]
        # Empty KB streaming: should have [DONE] at minimum
        assert any("[DONE]" in l for l in lines)

    async def test_streaming_format(self, api_client):
        kb_id = await _create_empty_kb(api_client)
        resp = await api_client.post("/api/local_doc_qa/local_doc_chat", json={
            "user_id": "testuser", "kb_ids": [kb_id],
            "question": "hello", "streaming": True
        })
        text = resp.text
        for line in text.split("\n"):
            if line.startswith("data: ") and "[DONE]" not in line:
                json_str = line[6:]
                parsed = json.loads(json_str)
                assert "code" in parsed
