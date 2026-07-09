"""Abstract base class for LLM adapters."""
from abc import ABC, abstractmethod
from collections.abc import Iterator

SSE_DATA_PREFIX = "data: "
SSE_DATA_PREFIX_LEN = len(SSE_DATA_PREFIX)


class BaseAdapter(ABC):
    """Each concrete adapter implements one LLM provider's API call logic
    and uniformly returns an SSE-formatted response stream.
    """

    def __init__(self, model: str, max_token: int, temperature: float,
                 top_p: float, stop_words: str | None = None):
        self.model      = model
        self.max_token  = max_token
        self.temperature = temperature
        self.top_p      = top_p
        self.stop_words = stop_words

    @abstractmethod
    def chat(self, messages: list[dict], stream: bool) -> Iterator[str]:
        """Call the LLM API and yield SSE-formatted strings.

        Content chunk: 'data: {"answer": "..."}'
        End marker:    'data: [DONE]\\n\\n'
        Error:         'data: {"answer": "LLM Error: ..."}'
        """
        ...
