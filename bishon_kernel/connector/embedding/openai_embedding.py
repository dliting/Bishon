"""OpenAI-compatible embedding client (replaces the Triton-based embedding service)."""
import concurrent.futures
import os
import time

from bishon_kernel.utils.custom_log import debug_logger

# .env is loaded centrally by bishon_kernel.configs.model_config; do not reload here.

EMBEDDING_API_KEY    = os.getenv("EMBEDDING_API_KEY", "EMPTY")
EMBEDDING_API_BASE   = os.getenv("EMBEDDING_API_BASE", "http://localhost:11434/v1/embeddings")
EMBEDDING_MODEL_NAME = os.getenv("EMBEDDING_MODEL_NAME", "qwen3-embedding:0.6b")

# Strip trailing /embeddings if present to get base URL
BASE_URL = EMBEDDING_API_BASE.rstrip('/')
if BASE_URL.endswith('/embeddings'):
    BASE_URL = BASE_URL[:-len('/embeddings')]

EMBEDDING_BATCH_SIZE    = int(os.getenv("EMBEDDING_BATCH_SIZE", 16))
EMBEDDING_MAX_WORKERS   = int(os.getenv("EMBEDDING_MAX_WORKERS", 4))
EMBEDDING_MAX_RETRIES   = int(os.getenv("EMBEDDING_MAX_RETRIES", 3))
EMBEDDING_RETRY_DELAY   = float(os.getenv("EMBEDDING_RETRY_DELAY", "1.0"))

debug_logger.info("Embedding client: base_url=%s, model=%s", BASE_URL, EMBEDDING_MODEL_NAME)


class OpenAIEmbeddings:
    """OpenAI-compatible embedding client.

    Supports Ollama, vLLM, and any OpenAI-compatible embedding endpoint.
    Replaces the legacy local embedding + Triton embedding service.
    """

    model_name: str = EMBEDDING_MODEL_NAME

    def __init__(self):
        from openai import OpenAI
        self.client = OpenAI(base_url=BASE_URL, api_key=EMBEDDING_API_KEY)

    def _get_embedding(self, queries: list[str]) -> list[list[float]]:
        """Get embeddings for a batch of queries with retry on transient failures."""
        last_error = None
        for attempt in range(1, EMBEDDING_MAX_RETRIES + 1):
            try:
                response = self.client.embeddings.create(
                    model=self.model_name,
                    input=queries,
                )
                embeddings = [d.embedding for d in response.data]
                return embeddings
            except Exception as e:
                last_error = e
                if attempt < EMBEDDING_MAX_RETRIES:
                    delay = EMBEDDING_RETRY_DELAY * (2 ** (attempt - 1))
                    debug_logger.warning(
                        "Embedding API error (attempt %d/%d), retrying in %.1fs: %s",
                        attempt, EMBEDDING_MAX_RETRIES, delay, e,
                    )
                    time.sleep(delay)
        debug_logger.error(
            "Embedding API error after %d attempts: %s", EMBEDDING_MAX_RETRIES, last_error,
        )
        raise last_error

    def _get_len_safe_embeddings(self, texts: list[str]) -> list[list[float]]:
        """Get embeddings for all texts with batching. Compatible with existing interface."""
        all_embeddings = []

        with concurrent.futures.ThreadPoolExecutor(max_workers=EMBEDDING_MAX_WORKERS) as executor:
            futures = []
            for i in range(0, len(texts), EMBEDDING_BATCH_SIZE):
                batch = texts[i:i + EMBEDDING_BATCH_SIZE]
                future = executor.submit(self._get_embedding, batch)
                futures.append(future)
            debug_logger.info('embedding batches: %d', len(futures))
            for future in futures:
                embeddings = future.result()
                all_embeddings += embeddings
        return all_embeddings

    @property
    def embed_version(self):
        return "openai_compatible_v1"

    def __hash__(self):
        return hash(self.model_name)
