"""Tests for FaissClient vector index operations."""
import os

import numpy as np

from bishon_kernel.configs.model_config import FAISS_EMBEDDING_DIM
from bishon_kernel.connector.database.faiss.faiss_client import Document, FaissClient


def _make_embs(n, dim=FAISS_EMBEDDING_DIM):
    embs = np.random.randn(n, dim).astype(np.float32)
    norms = np.linalg.norm(embs, axis=1, keepdims=True)
    return (embs / norms).tolist()


def _make_docs(n):
    return [Document(page_content=f"content chunk {i}", metadata={}) for i in range(n)]


class TestFaissClientCreate:
    def test_creates_cpu_index(self, tmp_faiss):
        assert tmp_faiss.index is not None
        assert tmp_faiss.index.ntotal == 0
        assert tmp_faiss.index.d == FAISS_EMBEDDING_DIM

    def test_initial_state(self, tmp_faiss):
        assert tmp_faiss._next_id == 0
        assert len(tmp_faiss._chunk_meta) == 0


class TestFaissInsert:
    def test_insert_single_file(self, tmp_faiss):
        docs = _make_docs(3)
        embs = _make_embs(3)
        result = tmp_faiss.insert_files("f1", "test.txt", "/path/test.txt", docs, embs, kb_id="KB001")
        assert result is True
        assert tmp_faiss.index.ntotal == 3

    def test_insert_metadata_correct(self, tmp_faiss):
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "test.txt", "/path/test.txt", docs, embs)
        assert len(tmp_faiss._chunk_meta) == 2
        meta = list(tmp_faiss._chunk_meta.values())[0]
        assert meta["file_id"] == "f1"
        assert meta["file_name"] == "test.txt"

    def test_insert_multiple_files(self, tmp_faiss):
        for fid in ["f1", "f2"]:
            docs = _make_docs(2)
            embs = _make_embs(2)
            tmp_faiss.insert_files(fid, f"{fid}.txt", f"/{fid}.txt", docs, embs)
        assert tmp_faiss.index.ntotal == 4


class TestFaissSearch:
    def test_search_finds_inserted(self, tmp_faiss):
        docs = _make_docs(1)
        embs = _make_embs(1)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        results = tmp_faiss.search_emb_async(embs, top_k=1)
        assert len(results) == 1
        assert len(results[0]) >= 1
        assert results[0][0].metadata["file_id"] == "f1"

    def test_search_empty_index(self, tmp_faiss):
        embs = _make_embs(1)
        results = tmp_faiss.search_emb_async(embs)
        assert results == [[]]

    def test_search_top_k_limit(self, tmp_faiss):
        docs = _make_docs(5)
        embs = _make_embs(5)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        results = tmp_faiss.search_emb_async(embs[:1], top_k=3)
        assert len(results[0]) <= 3


class TestFaissDelete:
    def test_delete_file(self, tmp_faiss):
        docs = _make_docs(3)
        embs = _make_embs(3)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        tmp_faiss.delete_files(["f1"])
        assert tmp_faiss.index.ntotal == 0

    def test_delete_all_clears_meta(self, tmp_faiss):
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        tmp_faiss.delete_files(["f1"])
        assert len(tmp_faiss._chunk_meta) == 0
        assert tmp_faiss._next_id == 0

    def test_delete_partial(self, tmp_faiss):
        docs1 = _make_docs(2)
        embs1 = _make_embs(2)
        tmp_faiss.insert_files("f1", "a.txt", "/a.txt", docs1, embs1)
        docs2 = _make_docs(2)
        embs2 = _make_embs(2)
        tmp_faiss.insert_files("f2", "b.txt", "/b.txt", docs2, embs2)
        assert tmp_faiss.index.ntotal == 4
        tmp_faiss.delete_files(["f1"])
        assert tmp_faiss.index.ntotal == 2

    def test_delete_string_input(self, tmp_faiss):
        docs = _make_docs(1)
        embs = _make_embs(1)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        tmp_faiss.delete_files("f1")
        assert tmp_faiss.index.ntotal == 0


class TestFaissDeletePartition:
    def test_delete_partition(self, tmp_faiss):
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "a.txt", "/a.txt", docs, embs, kb_id="KB001")
        docs2 = _make_docs(2)
        embs2 = _make_embs(2)
        tmp_faiss.insert_files("f2", "b.txt", "/b.txt", docs2, embs2, kb_id="KB002")
        tmp_faiss.delete_partition("KB001")
        assert tmp_faiss.index.ntotal == 2


class TestFaissGetFiles:
    def test_get_existing_files(self, tmp_faiss):
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        result = tmp_faiss.get_files(["f1"])
        assert "f1" in result

    def test_get_nonexistent_files(self, tmp_faiss):
        result = tmp_faiss.get_files(["nonexistent"])
        assert result == []


class TestFaissSeparateList:
    def test_separate_list_consecutive(self, tmp_faiss):
        result = tmp_faiss.separate_list([1, 2, 3, 5, 6])
        assert result == [[1, 2, 3], [5, 6]]

    def test_separate_list_single(self, tmp_faiss):
        result = tmp_faiss.separate_list([5])
        assert result == [[5]]


class TestProcessGroupScore:
    """Tests process_group score calculation — verifies neighboring expanded chunks do not pollute the original score."""

    @staticmethod
    def _chunk_meta(file_id, indices, content_prefix="txt"):
        meta = {}
        for i in indices:
            meta[1000 + i] = {
                "chunk_id": f"{file_id}_{i}",
                "content": f"{content_prefix}_{i}",
            }
        return meta

    def test_single_hit_no_neighbors(self, tmp_faiss):
        """A single hit chunk with no neighbors -> score is correct."""
        l2_dist = 0.3
        group = [Document(
            page_content="hit",
            metadata={"chunk_id": "f1_5", "file_id": "f1", "file_name": "a.txt", "score": l2_dist}
        )]
        chunk_meta = self._chunk_meta("f1", [5])
        results = tmp_faiss.process_group(group, chunk_meta)
        assert len(results) == 1
        expected = float(format(1 - l2_dist, '.4f'))
        assert results[0].metadata["score"] == expected

    def test_hit_with_unscored_neighbors(self, tmp_faiss):
        """Hit chunk + unscored neighbors -> neighbors do not affect the score (regression test for the core bug)."""
        l2_dist = 0.5
        group = [Document(
            page_content="hit",
            metadata={"chunk_id": "f1_5", "file_id": "f1", "file_name": "a.txt", "score": l2_dist}
        )]
        chunk_meta = self._chunk_meta("f1", [4, 5, 6])
        results = tmp_faiss.process_group(group, chunk_meta)
        assert len(results) == 1
        # Before fix: neighbor default 0 → min() → 0 → score = 1.0
        expected = float(format(1 - l2_dist, '.4f'))
        assert results[0].metadata["score"] == expected
        assert results[0].metadata["score"] != 1.0

    def test_two_hits_picks_best(self, tmp_faiss):
        """Multiple hit chunks -> pick the score with the lowest L2 distance (most relevant)."""
        group = [
            Document(page_content="h1", metadata={
                "chunk_id": "f1_3", "file_id": "f1", "file_name": "a.txt", "score": 0.2
            }),
            Document(page_content="h2", metadata={
                "chunk_id": "f1_7", "file_id": "f1", "file_name": "a.txt", "score": 0.8
            }),
        ]
        chunk_meta = self._chunk_meta("f1", list(range(11)))
        results = tmp_faiss.process_group(group, chunk_meta)
        for doc in results:
            assert doc.metadata["score"] < 1.0
        best_score = float(format(1 - 0.2, '.4f'))
        scores = [doc.metadata["score"] for doc in results]
        assert best_score in scores

    def test_scores_vary_by_relevance(self, tmp_faiss):
        """Different L2 distances produce different relevance scores."""
        chunk_meta = self._chunk_meta("f1", [5])
        group_a = [Document(
            page_content="a", metadata={
                "chunk_id": "f1_5", "file_id": "f1", "file_name": "a.txt", "score": 0.1
            }
        )]
        group_b = [Document(
            page_content="b", metadata={
                "chunk_id": "f1_5", "file_id": "f1", "file_name": "a.txt", "score": 0.9
            }
        )]
        result_a = tmp_faiss.process_group(group_a, chunk_meta)
        result_b = tmp_faiss.process_group(group_b, chunk_meta)
        # Lower L2 distance → higher relevance score
        assert result_a[0].metadata["score"] > result_b[0].metadata["score"]

    def test_zero_l2_distance_produces_score_one(self, tmp_faiss):
        """L2 distance of 0 (perfect match) -> relevance score is 1.0."""
        group = [Document(
            page_content="hit",
            metadata={"chunk_id": "f1_5", "file_id": "f1", "file_name": "a.txt", "score": 0.0}
        )]
        chunk_meta = self._chunk_meta("f1", [5])
        results = tmp_faiss.process_group(group, chunk_meta)
        assert results[0].metadata["score"] == 1.0


class TestSearchScoreSemantics:
    """Semantic consistency of scores returned by search_emb_async:
    all documents (including csv/xlsx) use a uniform similarity score (higher = better),
    matching the score semantics of txt and other documents after context expansion.
    """

    def test_csv_self_query_score_high(self, tmp_faiss):
        """A csv document self-query (searching with its own embedding) should score near 1.0."""
        docs = _make_docs(1)
        embs = _make_embs(1)
        tmp_faiss.insert_files("f1", "data.csv", "/data.csv", docs, embs)
        results = tmp_faiss.search_emb_async(embs, top_k=1)
        score = results[0][0].metadata["score"]
        # Self-query IP score is ~1.0, so the converted similarity should also be ~1.0.
        assert score > 0.9

    def test_txt_self_query_score_high(self, tmp_faiss):
        """A txt document self-query should score near 1.0."""
        docs = _make_docs(3)
        embs = _make_embs(3)
        tmp_faiss.insert_files("f1", "readme.txt", "/readme.txt", docs, embs)
        results = tmp_faiss.search_emb_async(embs[:1], top_k=1)
        score = results[0][0].metadata["score"]
        assert score > 0.9

    def test_mixed_csv_txt_same_scale(self, tmp_faiss):
        """When mixing csv and txt documents, self-match scores should both be near 1.0 (same scale)."""
        np.random.seed(42)
        docs_csv = _make_docs(1)
        embs_csv = _make_embs(1)
        tmp_faiss.insert_files("csv1", "data.csv", "/data.csv", docs_csv, embs_csv)

        docs_txt = _make_docs(3)
        embs_txt = _make_embs(3)
        tmp_faiss.insert_files("txt1", "readme.txt", "/readme.txt", docs_txt, embs_txt)

        # Query each document with its own embedding -> both should score high.
        csv_results = tmp_faiss.search_emb_async(embs_csv, top_k=1)
        csv_score = csv_results[0][0].metadata["score"]

        txt_results = tmp_faiss.search_emb_async(embs_txt[:1], top_k=1)
        txt_score = txt_results[0][0].metadata["score"]

        # Both should be > 0.9 (self-match), proving scores share the same scale.
        assert csv_score > 0.9, f"csv self-query score {csv_score} should be > 0.9"
        assert txt_score > 0.9, f"txt self-query score {txt_score} should be > 0.9"


class TestFaissAtomicSave:
    """Tests FAISS atomic save and crash recovery."""

    def test_save_no_temp_residual(self, tmp_faiss, tmp_faiss_dir):
        """No .tmp file should remain after a normal save."""
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        assert not os.path.exists(tmp_faiss.index_path + '.tmp')
        assert not os.path.exists(tmp_faiss._meta_path + '.tmp')

    def test_recover_missing_metadata(self, tmp_faiss, tmp_faiss_dir):
        """When only .faiss exists and .meta.json is missing, auto-recover as an empty index."""
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)
        assert os.path.exists(tmp_faiss._meta_path)

        # Simulate metadata loss.
        os.remove(tmp_faiss._meta_path)

        # Reload should auto-recover.
        reloaded = FaissClient("test_user", ["KB_test"], threshold=1.1,
                               kb_manager=tmp_faiss.kb_manager)
        assert reloaded.index.ntotal == 0
        assert len(reloaded._chunk_meta) == 0
        # Orphaned files should be moved aside; disk stays clean.
        assert not os.path.exists(tmp_faiss.index_path)
        assert os.path.exists(tmp_faiss.index_path + '.bak')

    def test_recover_missing_index(self, tmp_faiss, tmp_faiss_dir):
        """When only .meta.json exists and .faiss is missing, auto-recover as an empty index."""
        docs = _make_docs(2)
        embs = _make_embs(2)
        tmp_faiss.insert_files("f1", "test.txt", "/test.txt", docs, embs)

        os.remove(tmp_faiss.index_path)

        reloaded = FaissClient("test_user", ["KB_test"], threshold=1.1,
                               kb_manager=tmp_faiss.kb_manager)
        assert reloaded.index.ntotal == 0
        assert len(reloaded._chunk_meta) == 0
        assert not os.path.exists(tmp_faiss._meta_path)
        assert os.path.exists(tmp_faiss._meta_path + '.bak')

    def test_cleanup_residual_tmp(self, tmp_faiss, tmp_faiss_dir):
        """Residual .tmp files should be cleaned up at load time."""
        # Create fake tmp files.
        with open(tmp_faiss.index_path + '.tmp', 'w') as f:
            f.write("fake")
        with open(tmp_faiss._meta_path + '.tmp', 'w') as f:
            f.write("fake")

        reloaded = FaissClient("test_user", ["KB_test"], threshold=1.1,
                               kb_manager=tmp_faiss.kb_manager)
        assert not os.path.exists(tmp_faiss.index_path + '.tmp')
        assert not os.path.exists(tmp_faiss._meta_path + '.tmp')
        assert reloaded.index.ntotal == 0
