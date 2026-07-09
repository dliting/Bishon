"""Rerank client (in-process transformers), replacing the Triton-based rerank service.

Supports two model families:
- Cross-encoder (e.g., BAAI/bge-reranker): AutoModelForSequenceClassification
- Generative reranker (e.g., Qwen3-Reranker): AutoModelForCausalLM + yes/no token scoring
"""
import logging
import os

from bishon_kernel.configs.model_config import root_path

_raw_model_path = os.getenv("RERANK_MODEL_PATH", "/opt/Bishon/V2/models/Qwen3-Reranker-0.6B")
RERANK_MODEL_PATH = _raw_model_path if os.path.isabs(_raw_model_path) else os.path.join(root_path, _raw_model_path)
RERANK_ENABLED = os.getenv("RERANK_ENABLED", "False").lower() in ("true", "1", "yes")

LOCAL_RERANK_MAX_LENGTH = 8192
LOCAL_RERANK_BATCH = 4


class LocalRerankBackend:
    """In-process reranker using HuggingFace transformers.

    Replaces the old Triton-based LocalRerankBackend.
    Supports Qwen3-Reranker (generative) and BGE-reranker (cross-encoder).
    """

    def __init__(self):
        self.enabled = RERANK_ENABLED
        self.model_type = None
        if not self.enabled:
            logging.info("[Rerank] Disabled via RERANK_ENABLED=False")
            return

        if not os.path.exists(RERANK_MODEL_PATH):
            logging.warning("[Rerank] Model not found at %s, skipping rerank", RERANK_MODEL_PATH)
            self.enabled = False
            return

        try:
            import torch
            from transformers import (
                AutoConfig,
                AutoModelForCausalLM,
                AutoModelForSequenceClassification,
                AutoTokenizer,
            )

            config = AutoConfig.from_pretrained(RERANK_MODEL_PATH, trust_remote_code=True)
            architectures = getattr(config, 'architectures', [])

            from bishon_kernel.utils.gpu_utils import can_use_torch_gpu
            self.device = torch.device("cuda" if can_use_torch_gpu() else "cpu")

            if any('CausalLM' in a for a in architectures):
                # Qwen3-Reranker: generative model with yes/no token scoring
                self.tokenizer = AutoTokenizer.from_pretrained(
                    RERANK_MODEL_PATH, trust_remote_code=True,
                    padding_side='left',
                )
                self.model = AutoModelForCausalLM.from_pretrained(
                    RERANK_MODEL_PATH, trust_remote_code=True,
                    torch_dtype=torch.float16 if self.device.type == 'cuda' else torch.float32,
                )
                self.model_type = "generative"
                # yes/no token IDs
                self._token_true_id = self.tokenizer.convert_tokens_to_ids("yes")
                self._token_false_id = self.tokenizer.convert_tokens_to_ids("no")
                # Prompt prefix/suffix
                self._prefix = (
                    '<|im_start|>system\n'
                    'Judge whether the Document meets the requirements based on the Query and the Instruct provided. '
                    'Note that the answer can only be "yes" or "no".<|im_end|>\n'
                    '<|im_start|>user\n'
                )
                self._suffix = '<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
                self._prefix_tokens = self.tokenizer.encode(self._prefix, add_special_tokens=False)
                self._suffix_tokens = self.tokenizer.encode(self._suffix, add_special_tokens=False)
                self._default_instruction = 'Given a web search query, retrieve relevant passages that answer the query'
            else:
                # Cross-encoder (e.g., BGE-reranker)
                self.tokenizer = AutoTokenizer.from_pretrained(RERANK_MODEL_PATH)
                self.model = AutoModelForSequenceClassification.from_pretrained(RERANK_MODEL_PATH)
                self.model_type = "cross_encoder"

            self.model.to(self.device)
            self.model.eval()
            self.max_length = LOCAL_RERANK_MAX_LENGTH
            self.batch_size = LOCAL_RERANK_BATCH
            logging.info("[Rerank] Loaded %s model from %s on %s", self.model_type, RERANK_MODEL_PATH, self.device)
        except ImportError:
            logging.warning("[Rerank] transformers/torch not installed, rerank disabled")
            self.enabled = False
        except Exception as e:
            logging.error("[Rerank] Failed to load model: %s", e)
            self.enabled = False

    def _format_pair(self, query: str, doc: str) -> str:
        """Format query-document pair for Qwen3-Reranker."""
        return (
            f"<Instruct>: {self._default_instruction}\n"
            f"<Query>: {query}\n"
            f"<Document>: {doc}"
        )

    def _predict_generative(self, query: str, passages: list[str]) -> list[float]:
        """Qwen3-Reranker: score by yes/no token log-softmax probability."""
        import torch

        all_scores = []
        for i in range(0, len(passages), self.batch_size):
            batch = passages[i:i + self.batch_size]
            pairs = [self._format_pair(query, p) for p in batch]

            # Tokenize without padding first to add prefix/suffix
            inputs = self.tokenizer(
                pairs, padding=False, truncation='longest_first',
                return_attention_mask=False,
                max_length=self.max_length - len(self._prefix_tokens) - len(self._suffix_tokens),
            )
            for j, ele in enumerate(inputs['input_ids']):
                inputs['input_ids'][j] = self._prefix_tokens + ele + self._suffix_tokens

            inputs = self.tokenizer.pad(inputs, padding=True, return_tensors="pt")
            inputs = {k: v.to(self.device) for k, v in inputs.items()}

            with torch.no_grad():
                outputs = self.model(**inputs)
                batch_scores = outputs.logits[:, -1, :]
                true_vec = batch_scores[:, self._token_true_id]
                false_vec = batch_scores[:, self._token_false_id]
                batch_scores = torch.stack([false_vec, true_vec], dim=1)
                batch_scores = torch.nn.functional.log_softmax(batch_scores, dim=1)
                scores = batch_scores[:, 1].exp().cpu().tolist()

            all_scores.extend(scores)

        return all_scores

    def _predict_cross_encoder(self, query: str, passages: list[str]) -> list[float]:
        """BGE-reranker style: sequence classification logits → sigmoid."""
        import numpy as np
        import torch

        pairs = [[query, passage] for passage in passages]
        all_scores = []

        for i in range(0, len(pairs), self.batch_size):
            batch = pairs[i:i + self.batch_size]
            inputs = self.tokenizer(
                batch, padding=True, truncation=True,
                max_length=self.max_length, return_tensors="pt",
            )
            inputs = {k: v.to(self.device) for k, v in inputs.items()}

            with torch.no_grad():
                outputs = self.model(**inputs)
                scores = outputs.logits.squeeze(-1).cpu().numpy()

            if scores.ndim == 0:
                scores = np.array([scores.item()])
            all_scores.extend(scores.tolist())

        if all_scores:
            all_scores = (1 / (1 + np.exp(-np.array(all_scores)))).tolist()
        return all_scores

    def predict(self, query: str, passages: list[str]) -> list[float]:
        """Score passages against query. Returns scores (higher = more relevant)."""
        if not self.enabled or not passages:
            return [0.5] * len(passages)

        if self.model_type == "generative":
            return self._predict_generative(query, passages)
        else:
            return self._predict_cross_encoder(query, passages)
