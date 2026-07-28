"""FAISS vector index management (replaces Milvus)."""
import json
import math
import os
from copy import deepcopy
from itertools import groupby
from threading import Lock

import faiss
import numpy as np

from bishon_kernel.configs.model_config import (
    CHUNK_SIZE,
    FAISS_EMBEDDING_DIM,
    VECTOR_SEARCH_TOP_K,
    root_path,
)
from bishon_kernel.utils.custom_log import debug_logger
from bishon_kernel.utils.gpu_utils import can_use_faiss_gpu

MAX_L2_DISTANCE_NORMALIZED = math.sqrt(2)  # unit vectors: max L2 distance
CONTEXT_EXPAND_WINDOW     = 200              # adjacent chunk window for context expansion


class Document:
    """Lightweight Document class to avoid a langchain dependency."""
    def __init__(self, page_content="", metadata=None):
        self.page_content = page_content
        self.metadata = metadata or {}


FAISS_DIR = os.path.join(root_path, 'BISHON_DB', 'faiss')
os.makedirs(FAISS_DIR, exist_ok=True)


class FaissClient:
    """FAISS-based vector index, replacing MilvusClient.

    Each user_id gets its own FAISS index file: BISHON_DB/faiss/{user_id}.faiss
    Chunk metadata (content, file_id, file_name, chunk_id) is stored in SQLite
    via a reference to KnowledgeBaseManager.
    """

    def __init__(self, user_id, kb_ids, *, threshold=1.1, kb_manager=None):
        self.user_id = user_id
        self.kb_ids = kb_ids
        self.threshold = threshold
        self.top_k = VECTOR_SEARCH_TOP_K
        self.kb_manager = kb_manager
        self._lock = Lock()
        self.index_path = os.path.join(FAISS_DIR, f'{user_id}.faiss')
        self._meta_path = os.path.join(FAISS_DIR, f'{user_id}.meta.json')
        # Map: chunk_id (int) -> {file_id, file_name, content, kb_id, chunk_id}
        self._chunk_meta = {}
        # Next integer ID for new chunks
        self._next_id = 0
        self._load_or_create()

    def _load_or_create(self):
        """Load existing FAISS index and metadata from disk, or create a new one."""
        # Clean up residual temp files from interrupted saves
        for tmp in (self.index_path + '.tmp', self._meta_path + '.tmp'):
            if os.path.exists(tmp):
                os.remove(tmp)
                debug_logger.warning('[FAISS] Cleaned up residual temp file: %s', tmp)

        index_exists = os.path.exists(self.index_path)
        meta_exists  = os.path.exists(self._meta_path)

        # Inconsistency: one file exists without the other → backup and rebuild
        if index_exists != meta_exists:
            for path in (self.index_path, self._meta_path):
                if os.path.exists(path):
                    bak = path + '.bak'
                    os.replace(path, bak)
                    debug_logger.warning(
                        '[FAISS] Inconsistent state for user %s: backed up %s → %s, rebuilding empty index',
                        self.user_id, path, bak,
                    )
            self._create_new()
            return

        if index_exists and meta_exists:
            try:
                self.index = faiss.read_index(self.index_path)
                # Validate dimension matches current embedding model
                if self.index.d != FAISS_EMBEDDING_DIM:
                    debug_logger.warning(
                        '[FAISS] Dimension mismatch for user %s: index=%d, expected=%d. Rebuilding index.',
                        self.user_id, self.index.d, FAISS_EMBEDDING_DIM,
                    )
                    self._create_new()
                    return
                with open(self._meta_path, encoding='utf-8') as f:
                    raw_meta = json.load(f)
                self._chunk_meta = {int(k): v for k, v in raw_meta.items()}
                self._next_id = max(self._chunk_meta.keys()) + 1 if self._chunk_meta else 0
                self._to_gpu_safe()
                debug_logger.info('[FAISS] Loaded index for user %s: %d vectors, %d metadata entries',
                                  self.user_id, self.index.ntotal, len(self._chunk_meta))
            except Exception as e:
                debug_logger.error('[FAISS] Failed to load index: %s, creating new one', e)
                self._create_new()
        else:
            self._create_new()

    def _create_new(self):
        """Create a new FAISS index with inner product similarity. Uses GPU if available."""
        self._make_index(FAISS_EMBEDDING_DIM)
        self._next_id = 0

    def _save(self):
        """Persist the FAISS index and chunk metadata to disk atomically.
        Writes to temp files first, then os.replace() for atomic swap.
        Caller must hold self._lock."""
        index_tmp = self.index_path + '.tmp'
        meta_tmp  = self._meta_path + '.tmp'

        # Write FAISS index to temp
        src = faiss.index_gpu_to_cpu(self.index) if self._use_gpu else self.index
        faiss.write_index(src, index_tmp)

        # Write metadata to temp
        meta_to_save = {str(k): v for k, v in self._chunk_meta.items()}
        with open(meta_tmp, 'w', encoding='utf-8') as f:
            json.dump(meta_to_save, f, ensure_ascii=False)

        # Atomic swap
        os.replace(index_tmp, self.index_path)
        os.replace(meta_tmp, self._meta_path)
        debug_logger.info('[FAISS] Saved index for %s: %d vectors', self.user_id, self.index.ntotal)

    def _make_index(self, dim):
        """Create a new index. Centralizes GPU/CPU decision and updates self._use_gpu / self._gpu_res."""
        self._gpu_res = None
        self._use_gpu = False
        if can_use_faiss_gpu():
            try:
                self._gpu_res = faiss.StandardGpuResources()
                gpu_config = faiss.GpuIndexFlatConfig()
                gpu_config.device = 0
                gpu_config.useFloat16 = False
                self.index = faiss.IndexIDMap(
                    faiss.GpuIndexFlatIP(self._gpu_res, dim, gpu_config))
                self._use_gpu = True
                debug_logger.info(
                    '[FAISS] Created GPU index for user %s', self.user_id)
                return
            except Exception as e:
                debug_logger.info(
                    '[FAISS] GPU unavailable for new index: %s', e)
        self.index = faiss.IndexIDMap(faiss.IndexFlatIP(dim))
        debug_logger.info(
            '[FAISS] Created CPU index for user %s', self.user_id)

    def _to_gpu_safe(self):
        """Migrate the current CPU index to GPU when config permits and GPU is available."""
        if not can_use_faiss_gpu():
            self._gpu_res = None
            self._use_gpu = False
            return
        # If this is already a GPU index, convert back to CPU first (clean state).
        try:
            base = faiss.index_gpu_to_cpu(self.index) if self._use_gpu else self.index
        except Exception:
            base = self.index
            self._use_gpu = False
        try:
            self._gpu_res = faiss.StandardGpuResources()
            self.index = faiss.index_cpu_to_gpu(self._gpu_res, 0, base)
            self._use_gpu = True
            debug_logger.info(
                '[FAISS] Migrated index to GPU for user %s', self.user_id)
        except Exception as e:
            self._gpu_res = None
            self._use_gpu = False
            self.index = base  # keep the CPU index
            debug_logger.info('[FAISS] GPU migration skipped: %s', e)

    def set_chunk_meta(self, chunk_meta: dict):
        """Set chunk metadata from SQLite after loading."""
        self._chunk_meta = chunk_meta
        if chunk_meta:
            self._next_id = max(self._next_id, max(chunk_meta.keys()) + 1)

    def search_emb_async(self, embs, expr='', top_k=None, client_timeout=None, queries=None):
        """Search FAISS index for similar vectors. Compatible with MilvusClient interface."""
        if top_k is None:
            top_k = self.top_k
        if isinstance(embs, list):
            embs = np.array(embs, dtype=np.float32)
        if embs.ndim == 1:
            embs = embs.reshape(1, -1)

        with self._lock:
            if self.index.ntotal == 0:
                return [[]]
            scores, ids = self.index.search(embs, min(top_k, self.index.ntotal))
            chunk_meta_snapshot = dict(self._chunk_meta)

        batch_result = []
        for query_scores, query_ids in zip(scores, ids, strict=False):
            cands = []
            for score, chunk_id in zip(query_scores, query_ids, strict=False):
                chunk_id_int = int(chunk_id)
                meta = chunk_meta_snapshot.get(chunk_id_int)
                if meta is None:
                    continue
                # FAISS IP score: higher = more similar. Convert to L2-like distance.
                # score is inner product of normalized vectors, range [-1, 1]
                # Convert to "distance" where lower = better (to match Milvus interface)
                l2_dist = 1.0 - float(score)
                doc = Document(
                    page_content=meta['content'],
                    metadata={
                        "score": l2_dist,
                        "file_id": meta['file_id'],
                        "file_name": meta['file_name'],
                        "chunk_id": meta['chunk_id'],
                    }
                )
                cands.append(doc)
            cands.sort(key=lambda x: x.metadata['score'])
            batch_result.append(cands)

        # Apply threshold filtering (same logic as parse_batch_result)
        new_result = []
        for cands in batch_result:
            valid = [c for c in cands if c.metadata['score'] <= self.threshold]
            if not valid:
                valid = cands[:top_k]
            # Split csv/xlsx (no expand) vs others (need expand)
            need_expand, not_need_expand = [], []
            for doc in valid:
                fname = doc.metadata.get('file_name', '')
                if fname.lower().split('.')[-1] in ['csv', 'xlsx']:
                    doc.metadata['kernel'] = doc.page_content
                    # Unify score to similarity (higher = better) matching process_group
                    doc.metadata['score'] = 1.0 - doc.metadata['score']
                    not_need_expand.append(doc)
                else:
                    need_expand.append(doc)
            expand_res = self.expand_cand_docs(need_expand, chunk_meta_snapshot)
            new_result.append(not_need_expand + expand_res)
        return new_result

    def insert_files(self, file_id, file_name, file_path, docs, embs, batch_size=1000, kb_id=None):
        """Insert document chunks into FAISS. Compatible with MilvusClient interface."""
        num_docs = len(docs)
        contents = [doc.page_content for doc in docs]

        with self._lock:
            for batch_start in range(0, num_docs, batch_size):
                batch_end = min(batch_start + batch_size, num_docs)
                batch_embs = []
                batch_ids = []
                batch_meta_entries = []

                for idx in range(batch_start, batch_end):
                    emb = embs[idx]
                    chunk_id_str = f'{file_id}_{idx}'
                    chunk_id_int = self._next_id
                    self._next_id += 1
                    batch_embs.append(emb)
                    batch_ids.append(chunk_id_int)
                    batch_meta_entries.append((chunk_id_int, {
                        'file_id': file_id,
                        'file_name': file_name,
                        'chunk_id': chunk_id_str,
                        'kb_id': kb_id or (self.kb_ids[0] if self.kb_ids else ''),
                        'content': contents[idx],
                    }))

                try:
                    embs_np = np.array(batch_embs, dtype=np.float32)
                    ids_np = np.array(batch_ids, dtype=np.int64)
                    self.index.add_with_ids(embs_np, ids_np)
                    for cid, meta in batch_meta_entries:
                        self._chunk_meta[cid] = meta
                    debug_logger.info('[FAISS] Inserted %d chunks for %s', len(batch_ids), file_name)
                except Exception as e:
                    debug_logger.error('[FAISS] Insert failed for %s: %s', file_name, e)
                    return False

            self._save()
            return True

    def delete_files(self, files_id):
        """Delete chunks by file_ids using FAISS native remove_ids."""
        if isinstance(files_id, str):
            files_id = [files_id]
        files_set = set(files_id)

        with self._lock:
            ids_to_remove = [cid for cid, meta in self._chunk_meta.items()
                             if meta['file_id'] in files_set]
            if not ids_to_remove and not self._chunk_meta:
                return

            if not ids_to_remove:
                self._save()
                debug_logger.info('[FAISS] Deleted files (no matching chunks): %s', files_id)
                return

            # GPU index: convert to CPU first (GPU doesn't support remove_ids)
            if self._use_gpu:
                cpu_index = faiss.index_gpu_to_cpu(self.index)
                self._gpu_res = None
                self._use_gpu = False
                self.index = cpu_index

            self.index.remove_ids(np.array(ids_to_remove, dtype=np.int64))

            for cid in ids_to_remove:
                del self._chunk_meta[cid]

            if not self._chunk_meta:
                self._make_index(self.index.d)
                self._next_id = 0
            else:
                self._next_id = max(self._chunk_meta.keys()) + 1

            self._to_gpu_safe()
            self._save()
        debug_logger.info('[FAISS] Deleted files: %s', files_id)

    def delete_partition(self, partition_name):
        """Delete all chunks belonging to a kb_id (partition)."""
        if isinstance(partition_name, str):
            partition_name = [partition_name]
        kb_set = set(partition_name)

        # Find all file_ids belonging to the target kb_ids
        file_ids_to_delete = set()
        with self._lock:
            for meta in self._chunk_meta.values():
                if meta.get('kb_id', '') in kb_set:
                    file_ids_to_delete.add(meta['file_id'])

        if file_ids_to_delete:
            self.delete_files(list(file_ids_to_delete))
        debug_logger.info('[FAISS] Partition deleted: %s (%d files)', partition_name, len(file_ids_to_delete))

    # ---- Context Expansion (ported from MilvusClient) ----

    def separate_list(self, ls):
        lists = []
        ls1 = [ls[0]]
        for i in range(1, len(ls)):
            if ls[i - 1] + 1 == ls[i]:
                ls1.append(ls[i])
            else:
                lists.append(ls1)
                ls1 = [ls[i]]
        lists.append(ls1)
        return lists

    def process_group(self, group, chunk_meta=None):
        if chunk_meta is None:
            chunk_meta = self._chunk_meta
        new_cands = []
        group.sort(key=lambda x: int(x.metadata['chunk_id'].split('_')[-1]))
        id_set = set()
        file_id = group[0].metadata['file_id']
        file_name = group[0].metadata['file_name']
        group_scores_map = {}
        cand_chunks_set = set()

        for cand_doc in group:
            current_chunk_id = int(cand_doc.metadata['chunk_id'].split('_')[-1])
            group_scores_map[current_chunk_id] = cand_doc.metadata['score']
            chunk_ids = {f'{file_id}_{i}' for i in range(current_chunk_id - CONTEXT_EXPAND_WINDOW, current_chunk_id + CONTEXT_EXPAND_WINDOW)}
            cand_chunks_set.update(chunk_ids)

        # Get content for all candidate chunks from metadata
        group_chunk_map = {}
        for _, meta in chunk_meta.items():
            if meta['chunk_id'] in cand_chunks_set:
                chunk_idx = int(meta['chunk_id'].split('_')[-1])
                group_chunk_map[chunk_idx] = meta['content']

        group_file_chunk_num = list(group_chunk_map.keys())

        for cand_doc in group:
            current_chunk_id = int(cand_doc.metadata['chunk_id'].split('_')[-1])
            doc = deepcopy(cand_doc)
            id_set.add(current_chunk_id)
            docs_len = len(doc.page_content)
            for k in range(1, CONTEXT_EXPAND_WINDOW):
                break_flag = False
                for expand_index in [current_chunk_id + k, current_chunk_id - k]:
                    if expand_index in group_file_chunk_num:
                        merge_content = group_chunk_map[expand_index]
                        if docs_len + len(merge_content) > CHUNK_SIZE:
                            break_flag = True
                            break
                        else:
                            docs_len += len(merge_content)
                            id_set.add(expand_index)
                if break_flag:
                    break

        id_list = sorted(list(id_set))
        id_lists = self.separate_list(id_list)
        for id_seq in id_lists:
            try:
                doc = None
                for seq_id in id_seq:
                    if seq_id == id_seq[0]:
                        doc = Document(
                            page_content=group_chunk_map[seq_id],
                            metadata={"score": 0, "file_id": file_id, "file_name": file_name}
                        )
                    else:
                        doc.page_content += " " + group_chunk_map[seq_id]
                scored = [group_scores_map[s] for s in id_seq if s in group_scores_map]
                doc_score = min(scored) if scored else MAX_L2_DISTANCE_NORMALIZED
                doc.metadata["score"] = float(format(1 - doc_score, '.4f'))
                kernel_ids = [seq_id for seq_id in id_seq if seq_id in group_scores_map]
                doc.metadata["kernel"] = '|'.join([group_chunk_map[seq_id] for seq_id in kernel_ids])
                new_cands.append(doc)
            except Exception as e:
                debug_logger.error("[FAISS] process_group error: %s", e)
        return new_cands

    def expand_cand_docs(self, cand_docs, chunk_meta=None):
        if not cand_docs:
            return []
        cand_docs = sorted(cand_docs, key=lambda x: x.metadata['file_id'])
        m_grouped = [list(g) for _, g in groupby(cand_docs, key=lambda x: x.metadata['file_id'])]
        debug_logger.info('[FAISS] expand group number: %s', len(m_grouped))

        new_cands = []
        for group in m_grouped:
            if not group:
                continue
            result = self.process_group(group, chunk_meta)
            if result:
                new_cands.extend(result)
        return new_cands

    def get_files(self, files_id):
        """Get valid file_ids from index."""
        with self._lock:
            valid = set()
            for meta in self._chunk_meta.values():
                if meta['file_id'] in files_id:
                    valid.add(meta['file_id'])
        return list(valid)
