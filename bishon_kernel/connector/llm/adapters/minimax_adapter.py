"""MiniMax M2.7 adapter — OpenAI-compatible + reasoning_split."""
import re

from .openai_adapter import OpenAIAdapter

THINK_STRIP_RE = re.compile(r'<think>.*?</think>\s*', re.DOTALL)


class MiniMaxAdapter(OpenAIAdapter):
    """MiniMax M2.7 — uses reasoning_split to separate thinking from content,
    with <think> tag filtering as safety net.
    """

    def __init__(self, base_url: str, api_key: str, model: str,
                 max_token: int, temperature: float, top_p: float,
                 stop_words: str | None = None):
        super().__init__(base_url, api_key, model, max_token, temperature,
                         top_p, stop_words)

    # ---- overrides --------------------------------------------------

    def _create_params(self, messages: list[dict], stream: bool) -> dict:
        params = super()._create_params(messages, stream)
        params["extra_body"] = {"reasoning_split": True}
        return params

    @staticmethod
    def _strip_thinking_tags(text: str) -> str:
        """Remove <think>...</think> blocks (safety net)."""
        return THINK_STRIP_RE.sub('', text).strip()

    def _extract_content_nonstream(self, response) -> str:
        # Parent may return reasoning text when content is empty (Qwen3.5 fallback).
        # For MiniMax with reasoning_split=True, content is always populated, so this
        # fallback rarely triggers. If it does, _strip_thinking_tags is a no-op on
        # reasoning text (no <think> tags), which is acceptable.
        text = super()._extract_content_nonstream(response)
        return self._strip_thinking_tags(text)

    def _process_stream_chunk(self, delta: dict) -> str | None:
        """Filter <think> tags from streaming deltas.

        Uses a stateful approach since <think> and </think> may span
        multiple chunks.
        """
        if not hasattr(self, '_in_think'):
            self._in_think = False

        text = delta.get('content', '') or ''
        if not text:
            return None

        if '<think>' in text:
            self._in_think = True

        if self._in_think:
            if '</think>' in text:
                text = text.split('</think>', 1)[-1]
                self._in_think = False
            else:
                return None

        text = text.strip()
        return text if text else None
