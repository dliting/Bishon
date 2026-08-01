"""Tests for TrackedExecutor — pending/active count tracking."""
import time

import pytest

from bishon_kernel.monitoring.tracked_executor import TrackedExecutor


@pytest.fixture
def executor():
    ex = TrackedExecutor(max_workers=2)
    yield ex
    ex.shutdown(wait=True)


class TestTrackedExecutorCounts:
    def test_initial_counts_zero(self, executor):
        assert executor.pending_count == 0
        assert executor.active_count == 0

    def test_pending_increases_on_submit(self, executor):
        """Submitting a slow task should increase pending count."""
        import threading
        barrier = threading.Barrier(2)

        def slow_task():
            barrier.wait()
            time.sleep(0.1)

        executor.submit(slow_task)
        # The task may have already started, so pending could be 0 or 1
        # and active could be 0 or 1. Total should be 1.
        total = executor.pending_count + executor.active_count
        assert total >= 1
        barrier.wait()

    def test_counts_return_to_zero(self, executor):
        """After tasks complete, counts should return to zero."""
        executor.submit(lambda: time.sleep(0.05))
        executor.submit(lambda: time.sleep(0.05))
        time.sleep(0.3)  # Wait for tasks to complete
        assert executor.pending_count == 0
        assert executor.active_count == 0

    def test_multiple_tasks(self, executor):
        """Submit multiple tasks and verify counts."""
        import threading
        barrier = threading.Barrier(3)

        def blocked_task():
            barrier.wait()

        f1 = executor.submit(blocked_task)
        f2 = executor.submit(blocked_task)

        # Wait a bit for tasks to start
        time.sleep(0.1)

        # At least 2 tasks should be in the system
        total = executor.pending_count + executor.active_count
        assert total >= 2

        # Release the barrier
        barrier.wait()

        # Wait for completion
        f1.result(timeout=2)
        f2.result(timeout=2)
        time.sleep(0.1)

        assert executor.pending_count == 0
        assert executor.active_count == 0

    def test_max_workers_accessible(self, executor):
        assert executor.max_workers == 2

    def test_submit_after_shutdown_decrements_pending(self):
        """Submitting after shutdown should raise RuntimeError and not leak pending count."""
        ex = TrackedExecutor(max_workers=1)
        ex.shutdown(wait=True)
        with pytest.raises(RuntimeError):
            ex.submit(lambda: None)
        assert ex.pending_count == 0
