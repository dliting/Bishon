"""Bishon V2 configuration — removes all Docker/Triton/Milvus dependencies."""
import logging
import os

from dotenv import load_dotenv

# Resolve project root (V2 root = two levels above bishon_kernel)
current_script_path = os.path.abspath(__file__)
root_path = os.path.dirname(os.path.dirname(os.path.dirname(current_script_path)))

# Explicit .env path so the config is found regardless of CWD.
# This is the single .env entry point; other modules should not call load_dotenv again.
load_dotenv(os.path.join(root_path, '.env'))

UPLOAD_ROOT_PATH = os.path.join(root_path, "BISHON_DB", "content")
os.makedirs(UPLOAD_ROOT_PATH, exist_ok=True)
logging.info("UPLOAD_ROOT_PATH: %s", UPLOAD_ROOT_PATH)

# LLM streaming response
STREAMING = True

PROMPT_TEMPLATE = """参考信息：
{context}
---
我的问题或指令：
{question}
---
请根据上述参考信息回答我的问题或回复我的指令。前面的参考信息可能有用，也可能没用，你需要从我给出的参考信息中选出与我的问题最相关的那些，来为你的回答提供依据。回答一定要忠于原文，简洁但不丢信息，不要胡乱编造。我的问题或指令是什么语种，你就用什么语种回复,
你的回复："""

# Max cached knowledge-base instances
CACHED_VS_NUM = 100

# Sentence length for text splitting
SENTENCE_SIZE = 100

# Chunk size for each retrieved context segment
CHUNK_SIZE = 800

# Number of history turns sent to the LLM
LLM_HISTORY_LEN = 3

# Top-K matched chunks returned per knowledge-base search
VECTOR_SEARCH_TOP_K = 100

# Vector-search similarity threshold
VECTOR_SEARCH_SCORE_THRESHOLD = 1.1

# Document relevance threshold (docs with mean relevance below this are not returned)
DOC_SCORE_THRESHOLD = float(os.getenv("DOC_SCORE_THRESHOLD", "0.65"))

# Chinese title enhancement
ZH_TITLE_ENHANCE = False

# FAISS vector dimension (must match the embedding model output)
# qwen3-embedding:0.6b -> 1024; nomic-embed-text -> 768; bge-m3 -> 1024
FAISS_EMBEDDING_DIM = int(os.getenv("FAISS_EMBEDDING_DIM", "1024"))
