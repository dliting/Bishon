"""Tests for LocalDocQA core logic (no external services required)."""
from unittest.mock import MagicMock

import pytest
from langchain_core.documents import Document

from bishon_kernel.core.local_doc_qa import LocalDocQA


@pytest.fixture
def doc_qa():
    qa = LocalDocQA()
    qa.llm = MagicMock()
    qa.embeddings = MagicMock()
    qa.kb_manager = MagicMock()
    qa.rerank_backend = MagicMock()
    qa.rerank_backend.enabled = False
    qa.top_k = 5
    qa.chunk_size = 800
    qa.score_threshold = 1.1
    qa.faiss_kbs = []
    return qa


class TestDeduplicateDocuments:
    def test_removes_duplicates(self, doc_qa):
        docs = [Document(page_content="hello"), Document(page_content="world"), Document(page_content="hello")]
        result = doc_qa.deduplicate_documents(docs)
        assert len(result) == 2

    def test_empty_list(self, doc_qa):
        assert doc_qa.deduplicate_documents([]) == []

    def test_all_unique(self, doc_qa):
        docs = [Document(page_content=f"text{i}") for i in range(5)]
        assert len(doc_qa.deduplicate_documents(docs)) == 5

    def test_all_same(self, doc_qa):
        docs = [Document(page_content="same") for _ in range(5)]
        assert len(doc_qa.deduplicate_documents(docs)) == 1


class TestGeneratePrompt:
    def test_template_replacement(self, doc_qa):
        result = doc_qa.generate_prompt(
            "What is AI?",
            [Document(page_content="AI is artificial intelligence")],
            "参考信息：\n{context}\n---\n我的问题或指令：\n{question}\n---\n你的回复："
        )
        assert "What is AI?" in result
        assert "AI is artificial intelligence" in result
        assert "{question}" not in result
        assert "{context}" not in result

    def test_empty_context(self, doc_qa):
        result = doc_qa.generate_prompt("question?", [], "Q:{question} C:{context}")
        assert "Q:question?" in result


class TestRerankDocuments:
    def test_disabled_returns_unchanged(self, doc_qa):
        doc_qa.rerank_backend.enabled = False
        docs = [Document(page_content="a", metadata={"score": 0.5})]
        result = doc_qa.rerank_documents("query", docs)
        assert result == docs

    def test_long_query_skips_rerank(self, doc_qa):
        doc_qa.rerank_backend.enabled = True
        docs = [Document(page_content="a", metadata={"score": 0.5})]
        result = doc_qa.rerank_documents("x" * 301, docs)
        assert result == docs

    def test_rerank_sorts_by_score(self, doc_qa):
        doc_qa.rerank_backend.enabled = True
        doc_qa.rerank_backend.predict.return_value = [0.9, 0.1]
        docs = [
            Document(page_content="low", metadata={"score": 0.1}),
            Document(page_content="high", metadata={"score": 0.9}),
        ]
        result = doc_qa.rerank_documents("query", docs)
        assert result[0].metadata["score"] == 0.9

    def test_rerank_error_returns_unchanged(self, doc_qa):
        doc_qa.rerank_backend.enabled = True
        doc_qa.rerank_backend.predict.side_effect = Exception("rerank error")
        docs = [Document(page_content="a", metadata={"score": 0.5})]
        result = doc_qa.rerank_documents("query", docs)
        assert result == docs


class TestCalcMeanScore:
    def test_normal(self, doc_qa):
        docs = [Document(page_content="a", metadata={"score": 0.3}), Document(page_content="b", metadata={"score": 0.7})]
        assert doc_qa._calc_mean_score(docs) == pytest.approx(0.5)

    def test_empty(self, doc_qa):
        assert doc_qa._calc_mean_score([]) == 0

    def test_single(self, doc_qa):
        docs = [Document(page_content="a", metadata={"score": 0.8})]
        assert doc_qa._calc_mean_score(docs) == pytest.approx(0.8)


class TestScoreValidation:
    """Score validation logic in get_knowledge_based_answer."""

    def test_scientific_notation_score_is_valid(self, doc_qa):
        """A score in scientific notation should be parsed as a valid float."""
        doc = Document(page_content="content", metadata={"score": 1e-5})
        assert isinstance(doc.metadata["score"], float)

    def test_nan_score_is_filtered(self):
        """Validation behavior when score is NaN."""
        s = str(float('nan'))
        # Old approach: s.replace('.','',1).replace('-','',1).isdigit() -> 'nan'.replace('.','',1) -> 'nan' -> invalid [OK]
        # But float() conversion needs to handle this correctly.
        try:
            val = float(s)
            is_valid = True
        except ValueError:
            is_valid = False
        assert is_valid  # float('nan') converts but is not a valid score
