"""Standard OpenAI-compatible adapter (no thinking mode handling)."""
import json
import logging
import traceback
from collections.abc import Iterator

from openai import OpenAI

from .base import SSE_DATA_PREFIX, BaseAdapter


class OpenAIAdapter(BaseAdapter):
    """Uses OpenAI-compatible chat completions API."""

    def __init__(self, base_url: str, api_key: str, model: str,
                 max_token: int, temperature: float, top_p: float,
                 stop_words: str | None = None):
        super().__init__(model, max_token, temperature, top_p, stop_words)
        self.client = OpenAI(base_url=base_url, api_key=api_key or "EMPTY")

    def _create_params(self, messages: list[dict], stream: bool) -> dict:
        """Build the API call parameters (overridable by subclasses)."""
        params = {
            "model": self.model,
            "messages": messages,
            "stream": stream,
            "max_tokens": int(self.max_token),
            "temperature": self.temperature,
            "top_p": self.top_p,
        }
        if self.stop_words:
            params["stop"] = [self.stop_words]
        return params

    def _extract_content_nonstream(self, response) -> str:
        """Extract content from a non-streaming response (overridable by subclasses)."""
        if response.choices:
            return response.choices[0].message.content or ''
        return ''

    def _process_stream_chunk(self, delta: dict) -> str | None:
        """Process a single streaming delta; return content or None (overridable by subclasses)."""
        return delta.get('content', '') or None

    # ---- streaming --------------------------------------------------

    def _chat_stream(self, messages: list[dict]) -> Iterator[str]:
        params = self._create_params(messages, stream=True)
        try:
            response = self.client.chat.completions.create(**params)
            for event in response:
                if not isinstance(event, dict):
                    event = event.model_dump()
                choices = event.get('choices', [])
                if choices:
                    delta = choices[0].get('delta', {})
                    text = self._process_stream_chunk(delta)
                    if text:
                        yield SSE_DATA_PREFIX + json.dumps({'answer': text}, ensure_ascii=False)
        except Exception as e:
            logging.error("LLM streaming error: %s", traceback.format_exc())
            yield SSE_DATA_PREFIX + json.dumps({'answer': f"LLM Error: {e}"}, ensure_ascii=False)

    # ---- non-streaming ----------------------------------------------

    def _chat_nonstream(self, messages: list[dict]) -> Iterator[str]:
        params = self._create_params(messages, stream=False)
        try:
            response = self.client.chat.completions.create(**params)
            text = self._extract_content_nonstream(response)
        except Exception as e:
            logging.error("LLM non-streaming error: %s", traceback.format_exc())
            text = f"LLM Error: {e}"
        yield SSE_DATA_PREFIX + json.dumps({'answer': text}, ensure_ascii=False)

    # ---- public -----------------------------------------------------

    def chat(self, messages: list[dict], stream: bool) -> Iterator[str]:
        if stream:
            yield from self._chat_stream(messages)
        else:
            yield from self._chat_nonstream(messages)
        yield "data: [DONE]\n\n"
