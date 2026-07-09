"""Tests for OpenAILLM with a mocked adapter."""
import json
from unittest.mock import MagicMock, patch

import pytest


def _make_sse_chunks(texts: list[str]):
    """Helper: build SSE chunks a real adapter would yield."""
    for t in texts:
        yield "data: " + json.dumps({"answer": t}, ensure_ascii=False)
    yield "data: [DONE]\n\n"


@pytest.fixture
def mock_llm():
    with patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_KEY", "test-key"), \
         patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_BASE", "http://localhost:11434/v1"), \
         patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_MODEL_NAME", "test-model"), \
         patch("bishon_kernel.connector.llm.llm_for_openai_api.OPENAI_API_CONTEXT_LENGTH", 4096), \
         patch("bishon_kernel.connector.llm.llm_for_openai_api.LLM_PROVIDER", "openai"):
        from bishon_kernel.connector.llm.llm_for_openai_api import OpenAILLM
        llm = OpenAILLM()
        llm.adapter = MagicMock()
        return llm


class TestNumTokens:
    def test_string_messages(self, mock_llm):
        assert mock_llm.num_tokens_from_messages(["hello world"]) > 0

    def test_dict_messages(self, mock_llm):
        assert mock_llm.num_tokens_from_messages([{"role": "user", "content": "hello"}]) > 0


class TestNonStreamingCall:
    def test_returns_data_format(self, mock_llm):
        mock_llm.adapter.chat.return_value = _make_sse_chunks(["Test answer"])
        results = list(mock_llm._call("test prompt", [], streaming=False))
        assert len(results) == 2
        assert results[0].startswith("data: ")
        assert "[DONE]" in results[1]

    def test_api_error_yields_error_message(self, mock_llm):
        mock_llm.adapter.chat.return_value = iter([
            "data: {\"answer\": \"LLM Error: API Error\"}",
            "data: [DONE]\n\n",
        ])
        results = list(mock_llm._call("test", []))
        assert any("LLM Error" in r for r in results)


class TestStreamingCall:
    def test_yields_chunks(self, mock_llm):
        mock_llm.adapter.chat.return_value = _make_sse_chunks(["Hello", " world"])
        results = list(mock_llm._call("test", [], streaming=True))
        assert len(results) >= 2
        for r in results[:-1]:
            assert r.startswith("data: ")


class TestGeneratorAnswer:
    def test_returns_answer_result(self, mock_llm):
        mock_llm.adapter.chat.return_value = _make_sse_chunks(["answer"])
        results = list(mock_llm.generatorAnswer("test prompt", []))
        assert len(results) >= 1
        result = results[-1]
        assert hasattr(result, "history")
        assert hasattr(result, "llm_output")
        assert hasattr(result, "prompt")

    def test_api_error_yields_error_message(self, mock_llm):
        mock_llm.adapter.chat.return_value = iter([
            "data: {\"answer\": \"LLM Error: API Error\"}",
            "data: [DONE]\n\n",
        ])
        results = list(mock_llm._call("test", []))
        assert any("LLM Error" in r for r in results)
