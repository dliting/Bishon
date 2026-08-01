"""Bishon V2 - core QA logic using FAISS/SQLite/in-process Rerank."""
import logging
import os
import time
import traceback

from bishon_kernel.configs.model_config import (
    CHUNK_SIZE,
    DOC_SCORE_THRESHOLD,
    PROMPT_TEMPLATE,
    STREAMING,
    VECTOR_SEARCH_SCORE_THRESHOLD,
    VECTOR_SEARCH_TOP_K,
)
from bishon_kernel.connector.database.faiss.faiss_client import FaissClient
from bishon_kernel.connector.database.sqlite.sqlite_client import KnowledgeBaseManager
from bishon_kernel.connector.embedding.openai_embedding import OpenAIEmbeddings
from bishon_kernel.connector.llm import OpenAILLM
from bishon_kernel.connector.rerank.rerank_client import LocalRerankBackend
from bishon_kernel.monitoring.status_store import SERVICE_EMBEDDING, SERVICE_FAISS
from bishon_kernel.utils.custom_log import debug_logger
from bishon_kernel.utils.general_utils import get_time

from .local_file import LocalFile

_DOC_SCORE_THRESHOLD: float = DOC_SCORE_THRESHOLD
# Skip rerank for queries longer than this to avoid token-truncation semantic drift.
_RERANK_QUERY_MAX_LENGTH = 300


class LocalDocQA:
    def __init__(self):
        self.llm: OpenAILLM = None
        self.embeddings: OpenAIEmbeddings = None
        self.top_k: int = VECTOR_SEARCH_TOP_K
        self.chunk_size: int = CHUNK_SIZE
        self.score_threshold: float = VECTOR_SEARCH_SCORE_THRESHOLD
        self.faiss_kbs: list[FaissClient] = []
        self.kb_manager: KnowledgeBaseManager = None
        self.rerank_backend: LocalRerankBackend = None
        self.ocr_engine = None
        self.monitor_store = None  # Set by app.py after init

    # PaddleOCR is not thread-safe (it shares the PaddlePaddle GPU context),
    # so OCR calls must be serialized — do not switch to ThreadPoolExecutor.
    def _ocr_callable(self, image_data: dict):
        """Invoke PaddleOCR directly (replaces the HTTP microservice); returns a list of OCR texts."""
        from bishon_kernel.utils.ocr_utils import ocr_data_to_numpy
        img_array = ocr_data_to_numpy(image_data)

        results = self.ocr_engine.ocr(img_array)
        texts = []
        for res in results:
            rec_texts = res.get('rec_texts', [])
            texts.extend(rec_texts)
        return texts

    def init_cfg(self):
        """Initialize all components (called during FastAPI startup)."""
        self.embeddings = OpenAIEmbeddings()
        self.llm = OpenAILLM()
        self.kb_manager = KnowledgeBaseManager()
        self.rerank_backend = LocalRerankBackend()

        # PaddleOCR in-process initialization (PaddleOCR 3.x API).
        # Model files live under the project directory for offline deployment.
        from bishon_kernel.configs.model_config import root_path
        ocr_model_dir = os.path.join(root_path, 'models', 'paddleocr_models')

        det_dir    = os.path.join(ocr_model_dir, 'det')
        rec_dir    = os.path.join(ocr_model_dir, 'rec')
        cls_dir    = os.path.join(ocr_model_dir, 'cls')
        doc_ori_dir = os.path.join(ocr_model_dir, 'doc_ori')

        required_model_dirs = {
            'det': det_dir, 'rec': rec_dir, 'cls': cls_dir, 'doc_ori': doc_ori_dir,
        }
        missing = [name for name, d in required_model_dirs.items()
                   if not os.path.isdir(d) or not os.listdir(d)]
        if missing:
            logging.error(
                "[OCR] PaddleOCR model dirs missing or empty: %s. "
                "Please download models to %s", missing, ocr_model_dir
            )
            self.ocr_engine = None
        else:
            try:
                from paddleocr import PaddleOCR

                from bishon_kernel.utils.gpu_utils import can_use_ocr_gpu

                use_gpu = can_use_ocr_gpu()
                if use_gpu:
                    import paddle
                    paddle.device.set_device('gpu:0')

                self.ocr_engine = PaddleOCR(
                    text_detection_model_dir       = det_dir,
                    text_recognition_model_dir     = rec_dir,
                    textline_orientation_model_dir = cls_dir,
                    doc_orientation_classify_model_dir = doc_ori_dir,
                    use_doc_orientation_classify   = True,
                    use_doc_unwarping              = False,
                )
                logging.info("[OCR] PaddleOCR initialized, model_dir=%s, gpu=%s", ocr_model_dir, use_gpu)
            except Exception as e:
                logging.warning("[OCR] PaddleOCR init failed: %s, OCR will be unavailable", e)
                self.ocr_engine = None

        debug_logger.info("[SUCCESS] Bishon V2 核心初始化完成")

    def create_milvus_collection(self, user_id, kb_id, kb_name):
        """Name kept for interface compatibility; internally uses FAISS + SQLite."""
        # Enforce cache limit
        from bishon_kernel.configs.model_config import CACHED_VS_NUM
        while len(self.faiss_kbs) >= CACHED_VS_NUM:
            self.faiss_kbs.pop(0)

        faiss_kb = FaissClient(user_id, [kb_id], threshold=self.score_threshold, kb_manager=self.kb_manager)
        self.faiss_kbs.append(faiss_kb)
        self.kb_manager.new_milvus_base(kb_id, user_id, kb_name)

    def match_milvus_kb(self, user_id, kb_ids):
        # Normalize order to avoid duplicate instances
        kb_ids_sorted = sorted(kb_ids)
        for kb in self.faiss_kbs:
            if kb.user_id == user_id and sorted(kb.kb_ids) == kb_ids_sorted:
                debug_logger.info('match faiss_client: %s', kb)
                return kb

        # Enforce cache limit
        from bishon_kernel.configs.model_config import CACHED_VS_NUM
        while len(self.faiss_kbs) >= CACHED_VS_NUM:
            self.faiss_kbs.pop(0)

        faiss_kb = FaissClient(user_id, kb_ids_sorted, threshold=self.score_threshold, kb_manager=self.kb_manager)
        self.faiss_kbs.append(faiss_kb)
        return faiss_kb

    def insert_files_to_milvus(self, user_id, kb_id, local_files: list[LocalFile]):
        debug_logger.info('insert_files: %s', kb_id)
        faiss_kb = self.match_milvus_kb(user_id, [kb_id])

        for local_file in local_files:
            start = time.time()
            try:
                ocr_fn = self._ocr_callable if self.ocr_engine else None
                if ocr_fn is None:
                    ext = os.path.splitext(local_file.file_name)[1].lower()
                    if ext in ('.png', '.jpg', '.jpeg', '.pdf'):
                        debug_logger.warning(
                            "[OCR] PaddleOCR not available, image/PDF processing will fail: %s",
                            local_file.file_name
                        )
                local_file.split_file_to_docs(ocr_fn)
                content_length = sum(len(doc.page_content) for doc in local_file.docs)
            except Exception:
                debug_logger.error('split error: %s', traceback.format_exc())
                self.kb_manager.update_file_status(local_file.file_id, status='red')
                continue
            end = time.time()
            self.kb_manager.update_content_length(local_file.file_id, content_length)
            debug_logger.info('split time: %.2f, docs: %d', end - start, len(local_file.docs))

            start = time.time()
            try:
                local_file.create_embedding()
                if self.monitor_store:
                    latency = (time.time() - start) * 1000
                    self.monitor_store.record_outcome(
                        SERVICE_EMBEDDING, success=True, detail="embedding ok", latency_ms=latency,
                    )
            except Exception:
                debug_logger.error('embedding error: %s', traceback.format_exc())
                self.kb_manager.update_file_status(local_file.file_id, status='red')
                if self.monitor_store:
                    latency = (time.time() - start) * 1000
                    self.monitor_store.record_outcome(
                        SERVICE_EMBEDDING, success=False, detail="embedding error", latency_ms=latency,
                    )
                continue
            end = time.time()
            debug_logger.info('embedding time: %.2f, embs: %d', end - start, len(local_file.embs))

            self.kb_manager.update_chunk_size(local_file.file_id, len(local_file.docs))
            insert_start = time.time()
            ret = faiss_kb.insert_files(
                local_file.file_id, local_file.file_name, local_file.file_path,
                local_file.docs, local_file.embs, kb_id=kb_id
            )
            faiss_latency = (time.time() - insert_start) * 1000
            debug_logger.info('insert time: %.2f', time.time() - insert_start)
            if ret:
                self.kb_manager.update_file_status(local_file.file_id, status='green')
                if self.monitor_store:
                    self.monitor_store.record_outcome(
                        SERVICE_FAISS, success=True, detail="faiss insert ok", latency_ms=faiss_latency,
                    )
            else:
                self.kb_manager.update_file_status(local_file.file_id, status='yellow')
                if self.monitor_store:
                    self.monitor_store.record_outcome(
                        SERVICE_FAISS, success=False, detail="faiss insert failed", latency_ms=faiss_latency,
                    )

    def deduplicate_documents(self, source_docs):
        unique_docs = set()
        deduplicated_docs = []
        for doc in source_docs:
            if doc.page_content not in unique_docs:
                unique_docs.add(doc.page_content)
                deduplicated_docs.append(doc)
        return deduplicated_docs

    def get_source_documents(self, queries, faiss_kb, cosine_thresh=None, top_k=None):
        if not top_k:
            top_k = self.top_k
        source_documents = []
        embs = self.embeddings._get_len_safe_embeddings(queries)
        t1 = time.time()
        batch_result = faiss_kb.search_emb_async(embs=embs, top_k=top_k)
        t2 = time.time()
        debug_logger.info("faiss search time: %.2f", t2 - t1)
        for query, query_docs in zip(queries, batch_result, strict=False):
            for doc in query_docs:
                doc.metadata['retrieval_query'] = query
                doc.metadata['embed_version'] = self.embeddings.embed_version
                source_documents.append(doc)
        if cosine_thresh:
            source_documents = [item for item in source_documents
                              if float(item.metadata['score']) > cosine_thresh]
        return source_documents

    def reprocess_source_documents(self, query, source_docs, history, prompt_template):
        query_token_num = self.llm.num_tokens_from_messages([query])
        history_token_num = self.llm.num_tokens_from_messages(
            [x for sublist in history for x in sublist]
        )
        template_token_num = self.llm.num_tokens_from_messages([prompt_template])

        limited_token_nums = (
            self.llm.token_window - self.llm.max_token - self.llm.offcut_token
            - query_token_num - history_token_num - template_token_num
        )
        new_source_docs = []
        total_token_num = 0
        for doc in source_docs:
            doc_token_num = self.llm.num_tokens_from_docs([doc])
            if total_token_num + doc_token_num <= limited_token_nums:
                new_source_docs.append(doc)
                total_token_num += doc_token_num
            else:
                remaining = limited_token_nums - total_token_num
                doc_content = doc.page_content
                doc_token_num = self.llm.num_tokens_from_messages([doc_content])
                while doc_token_num > remaining:
                    if len(doc_content) > 2 * self.llm.truncate_len:
                        doc_content = doc_content[self.llm.truncate_len:-self.llm.truncate_len]
                    else:
                        doc_content = ""
                        break
                    doc_token_num = self.llm.num_tokens_from_messages([doc_content])
                doc.page_content = doc_content
                new_source_docs.append(doc)
                break
        return new_source_docs

    def generate_prompt(self, query, source_docs, prompt_template):
        context = "\n".join([doc.page_content for doc in source_docs])
        return prompt_template.replace("{question}", query).replace("{context}", context)

    def rerank_documents(self, query, source_documents):
        if not self.rerank_backend.enabled:
            return source_documents
        if len(query) > _RERANK_QUERY_MAX_LENGTH:
            return source_documents
        try:
            passages = [doc.page_content for doc in source_documents]
            scores = self.rerank_backend.predict(query, passages)
            for idx, score in enumerate(scores):
                source_documents[idx].metadata['score'] = float(score)
            source_documents.sort(key=lambda x: x.metadata['score'], reverse=True)
        except Exception:
            debug_logger.error("rerank error: %s", traceback.format_exc())
        return source_documents

    def _calc_mean_score(self, source_documents: list):
        if not source_documents:
            return 0
        total_score = sum(doc.metadata['score'] for doc in source_documents)
        return total_score / len(source_documents)

    @get_time
    def get_knowledge_based_answer(self, query, milvus_kb, chat_history=None,
                                   streaming: bool = STREAMING, rerank: bool = False):
        if chat_history is None:
            chat_history = []
        retrieval_queries = [query]

        source_documents = self.get_source_documents(retrieval_queries, milvus_kb)
        deduplicated_docs = self.deduplicate_documents(source_documents)
        # Scores are relevance-like: higher = better → sort descending
        retrieval_documents = sorted(deduplicated_docs, key=lambda x: x.metadata['score'], reverse=True)

        if rerank and self.rerank_backend.enabled and len(retrieval_documents) > 1:
            debug_logger.info("use rerank, docs: %d", len(retrieval_documents))
            retrieval_documents = self.rerank_documents(query, retrieval_documents)
            # After rerank, scores are probabilities (higher = better) → sort descending
            retrieval_documents = sorted(retrieval_documents, key=lambda x: x.metadata['score'], reverse=True)

        source_documents = self.reprocess_source_documents(
            query=query, source_docs=retrieval_documents,
            history=chat_history, prompt_template=PROMPT_TEMPLATE
        )

        filtered_documents = []
        for doc in source_documents:
            try:
                val = float(doc.metadata['score'])
                if not (val != val):  # NaN check
                    filtered_documents.append(doc)
            except (ValueError, TypeError):
                pass
        source_documents = filtered_documents

        mean_score = self._calc_mean_score(source_documents)
        if mean_score < _DOC_SCORE_THRESHOLD:
            source_documents = []
            prompt = query
        else:
            prompt = self.generate_prompt(
                query=query, source_docs=source_documents,
                prompt_template=PROMPT_TEMPLATE
            )

        t1 = time.time()
        for answer_result in self.llm.generatorAnswer(
            prompt=prompt, history=chat_history, streaming=streaming
        ):
            resp = answer_result.llm_output["answer"]
            prompt = answer_result.prompt
            history = answer_result.history
            history[-1][0] = query
            response = {
                "query": query,
                "prompt": prompt,
                "result": resp,
                "retrieval_documents": retrieval_documents,
                "source_documents": source_documents,
            }
            yield response, history
        t2 = time.time()
        debug_logger.info("LLM time: %.2f", t2 - t1)
