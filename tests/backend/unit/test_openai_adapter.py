"""Unit tests for OpenAIAdapter — reasoning fallback for thinking models."""
from unittest.mock import MagicMock

import pytest

from bishon_kernel.connector.llm.adapters.openai_adapter import OpenAIAdapter


@pytest.fixture
def adapter():
    """Create an OpenAIAdapter with a mocked OpenAI client."""
    adapter = OpenAIAdapter(
        base_url="http://localhost:8000/v1",
        api_key="EMPTY",
        model="test-model",
        max_token=1000,
        temperature=0.7,
        top_p=0.9,
    )
    adapter.client = MagicMock()
    return adapter


class TestExtractContentNonstream:
    """Test _extract_content_nonstream with various response shapes."""

    def test_normal_content(self, adapter):
        """Standard response: content field has text."""
        msg = MagicMock()
        msg.content = "Hello world"
        msg.reasoning = None
        response = MagicMock()
        response.choices = [MagicMock(message=msg)]

        result = adapter._extract_content_nonstream(response)
        assert result == "Hello world"

    def test_empty_content_with_reasoning(self, adapter):
        """Qwen3.5 reasoning mode: content is None, reasoning has text."""
        msg = MagicMock()
        msg.content = None
        msg.reasoning = "Thinking process..."
        response = MagicMock()
        response.choices = [MagicMock(message=msg)]

        result = adapter._extract_content_nonstream(response)
        assert result == "Thinking process..."

    def test_empty_content_no_reasoning(self, adapter):
        """Both content and reasoning are empty."""
        msg = MagicMock()
        msg.content = None
        msg.reasoning = None
        response = MagicMock()
        response.choices = [MagicMock(message=msg)]

        result = adapter._extract_content_nonstream(response)
        assert result == ''

    def test_content_takes_priority_over_reasoning(self, adapter):
        """When both fields have content, content wins."""
        msg = MagicMock()
        msg.content = "Final answer"
        msg.reasoning = "Thinking..."
        response = MagicMock()
        response.choices = [MagicMock(message=msg)]

        result = adapter._extract_content_nonstream(response)
        assert result == "Final answer"

    def test_empty_choices(self, adapter):
        """No choices in response."""
        response = MagicMock()
        response.choices = []

        result = adapter._extract_content_nonstream(response)
        assert result == ''


class TestProcessStreamChunk:
    """Test _process_stream_chunk with various delta shapes."""

    def test_content_delta(self, adapter):
        """Normal streaming delta with content."""
        delta = {"content": "Hello"}
        result = adapter._process_stream_chunk(delta)
        assert result == "Hello"

    def test_reasoning_delta(self, adapter):
        """Qwen3.5 reasoning delta: no content, only reasoning."""
        delta = {"reasoning": "Thinking..."}
        result = adapter._process_stream_chunk(delta)
        assert result == "Thinking..."

    def test_content_takes_priority(self, adapter):
        """Both fields present: content wins."""
        delta = {"content": "Answer", "reasoning": "Thinking"}
        result = adapter._process_stream_chunk(delta)
        assert result == "Answer"

    def test_empty_delta(self, adapter):
        """Both fields empty."""
        delta = {"content": "", "reasoning": ""}
        result = adapter._process_stream_chunk(delta)
        assert result is None

    def test_no_relevant_fields(self, adapter):
        """Delta with neither content nor reasoning."""
        delta = {"role": "assistant"}
        result = adapter._process_stream_chunk(delta)
        assert result is None
