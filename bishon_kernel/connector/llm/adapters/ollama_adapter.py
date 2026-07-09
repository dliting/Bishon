"""Ollama adapter — uses native /api/chat endpoint with think:false."""
import json
import logging
import traceback
from collections.abc import Iterator

import httpx

from .base import SSE_DATA_PREFIX, BaseAdapter


class OllamaAdapter(BaseAdapter):
    """Ollama native API adapter.

    Uses /api/chat (not the OpenAI-compatible endpoint) to support think: false,
    which fully disables the reasoning output of thinking models like qwen3.5.
    """

    def __init__(self, base_url: str, model: str, max_token: int,
                 temperature: float, top_p: float,
                 stop_words: str | None = None):
        super().__init__(model, max_token, temperature, top_p, stop_words)
        # Strip /v1 suffix from OpenAI-compatible URL to get native base
        api_base = base_url.rstrip('/')
        if api_base.endswith('/v1'):
            api_base = api_base[:-3]
        self._url   = f"{api_base}/api/chat"
        self._http  = httpx.Client(timeout=httpx.Timeout(300.0))

    def _build_body(self, messages: list[dict], stream: bool) -> dict:
        body = {
            "model": self.model,
            "messages": messages,
            "stream": stream,
            "think": False,
            "options": {
                "num_predict": int(self.max_token),
                "temperature": self.temperature,
                "top_p": self.top_p,
            },
        }
        if self.stop_words:
            body["options"]["stop"] = [self.stop_words]
        return body

    # ---- streaming --------------------------------------------------

    def _chat_stream(self, messages: list[dict]) -> Iterator[str]:
        body = self._build_body(messages, stream=True)
        try:
            with self._http.stream("POST", self._url, json=body) as resp:
                resp.raise_for_status()
                for line in resp.iter_lines():
                    if not line:
                        continue
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    content = chunk.get("message", {}).get("content", "")
                    if content:
                        yield SSE_DATA_PREFIX + json.dumps({'answer': content}, ensure_ascii=False)
        except Exception as e:
            logging.error("Ollama streaming error: %s", traceback.format_exc())
            yield SSE_DATA_PREFIX + json.dumps({'answer': f"LLM Error: {e}"}, ensure_ascii=False)

    # ---- non-streaming ----------------------------------------------

    def _chat_nonstream(self, messages: list[dict]) -> Iterator[str]:
        body = self._build_body(messages, stream=False)
        try:
            resp = self._http.post(self._url, json=body)
            resp.raise_for_status()
            data = resp.json()
            content = data.get("message", {}).get("content", "")
        except Exception as e:
            logging.error("Ollama non-streaming error: %s", traceback.format_exc())
            content = f"LLM Error: {e}"
        yield SSE_DATA_PREFIX + json.dumps({'answer': content}, ensure_ascii=False)

    # ---- public -----------------------------------------------------

    def chat(self, messages: list[dict], stream: bool) -> Iterator[str]:
        if stream:
            yield from self._chat_stream(messages)
        else:
            yield from self._chat_nonstream(messages)
        yield "data: [DONE]\n\n"
