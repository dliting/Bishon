"""GPU detection utilities: config + availability. Single entry point for all GPU-aware components."""
import os

# .env is loaded centrally by bishon_kernel.configs.model_config; do not reload here.


def _config_allows(env_key):
    """Check whether the env var permits GPU use. Defaults to allowed when unset."""
    return os.getenv(env_key, "true").lower() != "false"


def can_use_faiss_gpu():
    """True when config permits AND FAISS GPU is available."""
    if not _config_allows("VECTOR_DB_USE_GPU"):
        return False
    try:
        import faiss
        return faiss.get_num_gpus() > 0
    except Exception:
        return False


def can_use_torch_gpu():
    """True when config permits AND torch CUDA is available."""
    if not _config_allows("RERANK_USE_GPU"):
        return False
    try:
        import torch
        return torch.cuda.is_available()
    except ImportError:
        return False


def can_use_ocr_gpu():
    """True when config permits OCR GPU AND paddle is compiled with CUDA."""
    if not _config_allows("OCR_USE_GPU"):
        return False
    try:
        import paddle
        return paddle.device.is_compiled_with_cuda()
    except ImportError:
        return False
