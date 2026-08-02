"""Bishon V2 core kernel.

A local-first knowledge base QA system: FAISS + SQLite + FastAPI + PaddleOCR
+ in-process Rerank, with external OpenAI-compatible LLM/Embedding services.

Copyright (c) 2026 The Bishon V2 Authors. Licensed under the MIT License.
"""
import os

from dotenv import load_dotenv

# Load .env before any submodule runs: connector modules (llm_for_openai_api,
# openai_embedding, rerank_client) capture env vars at import time, and the app
# startup chain imports connector.llm (via handler.py) before model_config.
# Loading here guarantees every submodule's os.getenv sees the .env values.
# model_config.py keeps its own load_dotenv for direct-import contexts.
_PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(os.path.dirname(_PACKAGE_DIR), ".env"))
