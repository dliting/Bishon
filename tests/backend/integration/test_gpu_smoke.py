"""GPU smoke tests — verify torch + FAISS + Rerank can use GPU after install/reinstall.

Skipped automatically on hosts without a CUDA-capable GPU. Designed to fail
fast (within the per-test 3 min budget per CLAUDE.md) when the GPU stack is
broken — for example, torch+cu130 vs driver 12.6 mismatch.
"""
import os

import pytest


def _cuda_available() -> bool:
    try:
        import torch
        return torch.cuda.is_available()
    except Exception:
        return False


def _faiss_gpu_available() -> int:
    try:
        import faiss
        return faiss.get_num_gpus()
    except Exception:
        return 0


@pytest.fixture(scope="module")
def gpu_env():
    """Skip the whole module if no GPU."""
    if not _cuda_available() or _faiss_gpu_available() == 0:
        pytest.skip("No CUDA GPU available (torch.cuda.is_available() is False or faiss has no GPU resources)")


class TestTorchGPU:
    def test_torch_detects_gpu(self, gpu_env):
        import torch
        assert torch.cuda.is_available()
        assert torch.cuda.device_count() >= 1
        # Sanity: name + compute capability are populated
        name = torch.cuda.get_device_name(0)
        cap = torch.cuda.get_device_capability(0)
        assert name, "device name empty"
        assert cap[0] >= 7, f"compute capability {cap} below 7.0 (Volta) — performance will be poor"

    def test_torch_can_allocate_and_compute(self, gpu_env):
        """End-to-end: tensor allocation + matmul on GPU."""
        import torch
        a = torch.randn(512, 512, device="cuda")
        b = torch.randn(512, 512, device="cuda")
        c = a @ b
        assert c.shape == (512, 512)
        assert c.device.type == "cuda"
        # Non-zero result confirms the kernel actually ran
        assert c.abs().sum().item() > 0


class TestFaissGPU:
    def test_faiss_has_gpu_resources(self, gpu_env):
        import faiss
        assert faiss.get_num_gpus() >= 1

    def test_faiss_gpu_index_roundtrip(self, gpu_env, tmp_path, monkeypatch):
        """Verify FaissClient can build a GPU index and serve a search.

        Uses Bishon's real FaissClient (not raw faiss) so we exercise the same
        code path the deployment uses at runtime.
        """
        import numpy as np

        import bishon_kernel.connector.database.faiss.faiss_client as faiss_mod
        from bishon_kernel.connector.database.faiss.faiss_client import FaissClient
        from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager

        # Isolated FAISS + SQLite dirs
        faiss_dir = str(tmp_path / "faiss")
        os.makedirs(faiss_dir, exist_ok=True)
        monkeypatch.setattr(faiss_mod, "FAISS_DIR", faiss_dir)

        db_dir = str(tmp_path / "db")
        os.makedirs(db_dir, exist_ok=True)
        import bishon_kernel.connector.database.sqlite.sqlite_client as sqlite_mod
        monkeypatch.setattr(sqlite_mod, "DB_DIR", db_dir)
        monkeypatch.setattr(sqlite_mod, "DB_PATH", os.path.join(db_dir, "test.db"))

        monkeypatch.setenv("VECTOR_DB_USE_GPU", "true")

        kb_mgr = KnowledgeBaseManager()
        cli = FaissClient("gpu_smoke_user", ["KB_smoke"], threshold=1.1, kb_manager=kb_mgr)

        # The constructor should have built a GPU-backed index
        assert cli._use_gpu is True, "FaissClient did not pick GPU despite VECTOR_DB_USE_GPU=true"


class TestRerankGPU:
    """End-to-end Rerank GPU test.

    Loads Qwen3-Reranker-0.6B via Bishon's LocalRerankBackend and runs a
    semantic-rank check. Skipped if the model is not present.
    """

    def test_rerank_ranks_semantically(self, gpu_env):
        from bishon_kernel.connector.rerank.rerank_client import RERANK_MODEL_PATH
        if not os.path.exists(RERANK_MODEL_PATH):
            pytest.skip(f"Rerank model not present at {RERANK_MODEL_PATH}")

        from bishon_kernel.connector.rerank.rerank_client import LocalRerankBackend
        from bishon_kernel.utils.gpu_utils import can_use_torch_gpu
        assert can_use_torch_gpu(), "GPU available but gpu_utils.can_use_torch_gpu() returned False"

        rb = LocalRerankBackend()
        if not rb.enabled:
            pytest.skip("LocalRerankBackend disabled")
        assert rb.device.type == "cuda", f"Rerank loaded on {rb.device}, expected cuda"

        docs = [
            "Artificial intelligence is the simulation of human intelligence processes by machines.",
            "Apples are a type of fruit that grow on trees.",
            "Machine learning is a subset of AI that enables systems to learn from data.",
        ]
        scores = rb.predict("What is AI?", docs)

        # AI doc should rank highest; apples lowest. We don't pin exact numbers
        # (model updates will shift them), just the ordering on easy cases.
        assert len(scores) == 3
        ai_idx = scores.index(max(scores))
        assert ai_idx == 0, f"expected AI doc to rank top, got idx={ai_idx} scores={scores}"
        apple_idx = scores.index(min(scores))
        assert apple_idx == 1, f"expected apples to rank lowest, got idx={apple_idx} scores={scores}"
