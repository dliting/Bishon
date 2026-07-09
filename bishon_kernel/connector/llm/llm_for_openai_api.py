"""OpenAI API LLM client — supports multiple LLM providers via the adapter layer."""
import json
import logging
import os

from .adapters import MiniMaxAdapter, OllamaAdapter, OpenAIAdapter
from .adapters.base import SSE_DATA_PREFIX_LEN

# .env is loaded centrally by bishon_kernel.configs.model_config; do not reload here.

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE")
OPENAI_API_MODEL_NAME = os.getenv("OPENAI_API_MODEL_NAME")
OPENAI_API_CONTEXT_LENGTH = os.getenv("OPENAI_API_CONTEXT_LENGTH")
if isinstance(OPENAI_API_CONTEXT_LENGTH, str) and OPENAI_API_CONTEXT_LENGTH != '':
    OPENAI_API_CONTEXT_LENGTH = int(OPENAI_API_CONTEXT_LENGTH)

LLM_PROVIDER = os.getenv("LLM_PROVIDER", "openai").lower()

DEFAULT_SYSTEM_PROMPT = os.getenv("SYSTEM_PROMPT", "You are a helpful assistant.")
logging.info("OPENAI_API_BASE = %s", OPENAI_API_BASE)
logging.info("OPENAI_API_MODEL_NAME = %s", OPENAI_API_MODEL_NAME)

try:
    import tiktoken
    HAS_TIKTOKEN = True
except ImportError:
    HAS_TIKTOKEN = False


class AnswerResult:
    """LLM generation result entity."""
    history: list[list[str]]
    llm_output: dict | None
    prompt: str


class OpenAILLM:
    """OpenAI-compatible LLM client.

    Supports Ollama, vLLM, and any OpenAI-compatible chat API.
    """

    def __init__(self):
        self.model: str = OPENAI_API_MODEL_NAME or "gpt-3.5-turbo"
        self.token_window: int = OPENAI_API_CONTEXT_LENGTH or 8192
        self.max_token: int = (OPENAI_API_CONTEXT_LENGTH or 8192) // 2
        self.offcut_token: int = 50
        self.truncate_len: int = 50
        self.temperature: float = 0
        self.top_p: float = 0.001
        self.stop_words: str | None = None
        self.history_len: int = 2
        self.adapter = self._create_adapter()

    def _create_adapter(self):
        adapter_kw = dict(
            model=self.model, max_token=self.max_token,
            temperature=self.temperature, top_p=self.top_p,
            stop_words=self.stop_words,
        )
        if LLM_PROVIDER == "ollama":
            return OllamaAdapter(base_url=OPENAI_API_BASE, **adapter_kw)
        if LLM_PROVIDER == "minimax":
            return MiniMaxAdapter(base_url=OPENAI_API_BASE, api_key=OPENAI_API_KEY, **adapter_kw)
        return OpenAIAdapter(base_url=OPENAI_API_BASE, api_key=OPENAI_API_KEY, **adapter_kw)

    def _get_encoding(self, model=None):
        if not HAS_TIKTOKEN:
            # Fallback: approximate tokens by char count / 4
            return None
        if model is None:
            model = self.model
        try:
            return tiktoken.encoding_for_model(model)
        except KeyError:
            return tiktoken.get_encoding("cl100k_base")

    def num_tokens_from_messages(self, messages, model=None):
        encoding = self._get_encoding(model)
        if encoding is None:
            # Fallback: ~4 chars per token
            total = 0
            for msg in messages:
                if isinstance(msg, dict):
                    total += sum(len(v) // 4 for v in msg.values())
                elif isinstance(msg, str):
                    total += len(msg) // 4
            return total + 3
        num_tokens = 0
        for message in messages:
            if isinstance(message, dict):
                num_tokens += 3  # tokens per message
                for key, value in message.items():
                    num_tokens += len(encoding.encode(value))
            elif isinstance(message, str):
                num_tokens += len(encoding.encode(message))
            else:
                num_tokens += len(encoding.encode(str(message)))
        num_tokens += 3
        return num_tokens

    def num_tokens_from_docs(self, docs):
        encoding = self._get_encoding()
        if encoding is None:
            return sum(len(doc.page_content) // 4 for doc in docs)
        num_tokens = 0
        for doc in docs:
            num_tokens += len(encoding.encode(doc.page_content, disallowed_special=()))
        return num_tokens

    def _call(self, prompt: str, history: list[list[str]], streaming: bool = False):
        messages = [{"role": "system", "content": DEFAULT_SYSTEM_PROMPT}]
        for pair in history:
            if len(pair) >= 2:
                question, answer = pair[0], pair[1]
                messages.append({"role": "user", "content": question})
                messages.append({"role": "assistant", "content": answer})
        messages.append({"role": "user", "content": prompt})
        logging.info("LLM messages (history_len=%d, total=%d)", len(history), len(messages))
        yield from self.adapter.chat(messages, stream=streaming)

    def generatorAnswer(self, prompt: str, history: list[list[str]] = None,
                        streaming: bool = False):
        if history is None:
            history = []
        logging.info("LLM: history_len=%d, streaming=%s", len(history), streaming)

        response = self._call(prompt, history, streaming)
        complete_answer = ""
        for response_text in response:
            if response_text:
                chunk_str = response_text[SSE_DATA_PREFIX_LEN:]
                if not chunk_str.startswith("[DONE]"):
                    chunk_js = json.loads(chunk_str)
                    complete_answer += chunk_js.get("answer", "")
            if len(history) == 0:
                history = [[]]
            history[-1] = [prompt, complete_answer]
            result = AnswerResult()
            result.history = history
            result.llm_output = {"answer": response_text}
            result.prompt = prompt
            yield result
