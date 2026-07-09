"""Tests for LocalRerankBackend."""
from unittest.mock import patch


class TestRerankDisabled:
    def test_disabled_returns_default_scores(self):
        with patch("bishon_kernel.connector.rerank.rerank_client.RERANK_ENABLED", False):
            from bishon_kernel.connector.rerank.rerank_client import LocalRerankBackend
            backend = LocalRerankBackend()
            assert backend.enabled is False
            scores = backend.predict("query", ["a", "b"])
            assert scores == [0.5, 0.5]

    def test_model_not_found_disables(self):
        with patch("bishon_kernel.connector.rerank.rerank_client.RERANK_ENABLED", True), \
             patch("bishon_kernel.connector.rerank.rerank_client.RERANK_MODEL_PATH", "/nonexistent/path"):
            from bishon_kernel.connector.rerank.rerank_client import LocalRerankBackend
            backend = LocalRerankBackend()
            assert backend.enabled is False

    def test_empty_passages(self):
        with patch("bishon_kernel.connector.rerank.rerank_client.RERANK_ENABLED", True), \
             patch("bishon_kernel.connector.rerank.rerank_client.RERANK_MODEL_PATH", "/nonexistent"):
            from bishon_kernel.connector.rerank.rerank_client import LocalRerankBackend
            backend = LocalRerankBackend()
            assert backend.predict("query", []) == []
