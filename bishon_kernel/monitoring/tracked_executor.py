"""ThreadPoolExecutor wrapper that tracks pending and active task counts."""
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Callable


class TrackedExecutor(ThreadPoolExecutor):
    """Drop-in replacement for ThreadPoolExecutor that exposes queue depth.

    Tracks:
    - pending_count: tasks submitted but not yet running
    - active_count:  tasks currently executing
    """

    def __init__(self, max_workers: int | None = None, **kwargs):
        super().__init__(max_workers=max_workers, **kwargs)
        self._pending_count = 0
        self._active_count  = 0
        self._lock          = threading.Lock()

    def submit(self, fn: Callable, /, *args, **kwargs):  # noqa: ANN201
        """Submit a task, tracking its lifecycle from pending → active → done."""
        with self._lock:
            self._pending_count += 1

        def _tracked_fn():
            # Transition: pending → active
            with self._lock:
                self._pending_count -= 1
                self._active_count  += 1
            try:
                return fn(*args, **kwargs)
            finally:
                with self._lock:
                    self._active_count -= 1

        try:
            future = super().submit(_tracked_fn)
        except RuntimeError:
            # Executor was shut down — undo the pending increment
            with self._lock:
                self._pending_count -= 1
            raise
        return future

    @property
    def pending_count(self) -> int:
        """Number of tasks waiting in the queue."""
        with self._lock:
            return self._pending_count

    @property
    def active_count(self) -> int:
        """Number of tasks currently executing."""
        with self._lock:
            return self._active_count

    @property
    def max_workers(self) -> int:
        """Maximum number of worker threads."""
        return self._max_workers
