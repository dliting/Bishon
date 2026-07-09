"""Tests for OpenAIEmbeddings with a mocked SDK."""
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def mock_emb():
    with patch("bishon_kernel.connector.embedding.openai_embedding.EMBEDDING_API_KEY", "test"), \
         patch("bishon_kernel.connector.embedding.openai_embedding.BASE_URL", "http://localhost/v1"):
        from bishon_kernel.connector.embedding.openai_embedding import OpenAIEmbeddings
        emb = OpenAIEmbeddings()
        emb.client = MagicMock()
        return emb


class TestGetEmbedding:
    def test_returns_vectors(self, mock_emb):
        mock_data = [MagicMock(embedding=[0.1] * 768), MagicMock(embedding=[0.2] * 768)]
        mock_resp = MagicMock()
        mock_resp.data = mock_data
        mock_emb.client.embeddings.create.return_value = mock_resp
        result = mock_emb._get_embedding(["hello", "world"])
        assert len(result) == 2
        assert len(result[0]) == 768

    def test_api_error_raises(self, mock_emb):
        mock_emb.client.embeddings.create.side_effect = Exception("API Error")
        with pytest.raises(Exception, match="API Error"):
            mock_emb._get_embedding(["test"])

    def test_retries_on_transient_failure(self, mock_emb):
        """API fails twice then succeeds — should retry and return result."""
        mock_data = [MagicMock(embedding=[0.1] * 768)]
        mock_resp = MagicMock()
        mock_resp.data = mock_data
        mock_emb.client.embeddings.create.side_effect = [
            Exception("timeout"),
            Exception("connection reset"),
            mock_resp,
        ]
        with patch("bishon_kernel.connector.embedding.openai_embedding.time") as mock_time:
            result = mock_emb._get_embedding(["test"])
        assert len(result) == 1
        assert mock_emb.client.embeddings.create.call_count == 3
        mock_time.sleep.assert_called()

    def test_retries_exhausted_raises(self, mock_emb):
        """API fails all retries — should raise the last error."""
        mock_emb.client.embeddings.create.side_effect = Exception("persistent error")
        with patch("bishon_kernel.connector.embedding.openai_embedding.time"):
            with pytest.raises(Exception, match="persistent error"):
                mock_emb._get_embedding(["test"])
        assert mock_emb.client.embeddings.create.call_count == 3


class TestGetLenSafeEmbeddings:
    def test_single_batch(self, mock_emb):
        mock_data = [MagicMock(embedding=[0.1] * 768)]
        mock_resp = MagicMock()
        mock_resp.data = mock_data
        mock_emb.client.embeddings.create.return_value = mock_resp
        result = mock_emb._get_len_safe_embeddings(["test"])
        assert len(result) == 1

    def test_multiple_batches(self, mock_emb):
        def _mock_create(**kwargs):
            n = len(kwargs["input"])
            resp = MagicMock()
            resp.data = [MagicMock(embedding=[0.1] * 768)] * n
            return resp

        texts = [f"text{i}" for i in range(20)]
        mock_emb.client.embeddings.create.side_effect = _mock_create
        result = mock_emb._get_len_safe_embeddings(texts)
        assert len(result) == 20


class TestEmbedVersion:
    def test_version_string(self, mock_emb):
        assert mock_emb.embed_version == "openai_compatible_v1"

    def test_hash(self, mock_emb):
        assert isinstance(hash(mock_emb), int)
