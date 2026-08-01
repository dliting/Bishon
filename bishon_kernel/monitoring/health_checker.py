"""Background health checker — runs probes periodically and on demand."""
from __future__ import annotations

import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor
from typing import TYPE_CHECKING

from bishon_kernel.monitoring.service_probes import ALL_PROBES
from bishon_kernel.monitoring.status_store import STATUS_UNHEALTHY, ServiceStatusStore
from bishon_kernel.monitoring.tracked_executor import TrackedExecutor

if TYPE_CHECKING:
    from bishon_kernel.core.local_doc_qa import LocalDocQA

logger = logging.getLogger(__name__)

CHECK_INTERVAL_SECONDS = 60
_PROBE_MAX_WORKERS = 2


class HealthChecker:
    """Orchestrates periodic background health checks.

    Started/stopped via FastAPI lifespan.  Probes run in a separate
    executor to avoid blocking the event loop.
    """

    def __init__(
        self,
        local_doc_qa: LocalDocQA,
        store: ServiceStatusStore,
        executor: TrackedExecutor,
    ):
        self._local_doc_qa    = local_doc_qa
        self._store           = store
        self._executor        = executor
        self._task: asyncio.Task | None = None
        self._probe_executor  = ThreadPoolExecutor(
            max_workers=_PROBE_MAX_WORKERS, thread_name_prefix="health-probe",
        )

    async def start(self) -> None:
        """Start the periodic check loop (call from FastAPI lifespan)."""
        self._task = asyncio.create_task(self._periodic_check())
        logger.info("HealthChecker started (interval=%ds)", CHECK_INTERVAL_SECONDS)

    async def stop(self) -> None:
        """Cancel the background task."""
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        logger.info("HealthChecker stopped")

    def shutdown(self) -> None:
        """Shut down the probe executor. Call after stop() during app shutdown."""
        self._probe_executor.shutdown(wait=False)

    async def _periodic_check(self) -> None:
        """Run all probes every CHECK_INTERVAL_SECONDS."""
        # Immediate first check
        await self._run_probes()

        while True:
            await asyncio.sleep(CHECK_INTERVAL_SECONDS)
            await self._run_probes()

    async def _run_probes(self) -> None:
        """Execute all probes and update the status store."""
        loop = asyncio.get_running_loop()

        # Run probes in executor to avoid blocking the event loop
        for name, probe_fn in ALL_PROBES.items():
            try:
                status, detail, latency = await loop.run_in_executor(
                    self._probe_executor, probe_fn, self._local_doc_qa,
                )
                self._store.record_probe(
                    name=name,
                    status=status,
                    detail=detail,
                    latency_ms=latency,
                )
            except Exception:
                logger.error("Probe %s failed with exception", name, exc_info=True)
                self._store.record_probe(
                    name=name,
                    status=STATUS_UNHEALTHY,
                    detail="probe error",
                )

        # Record queue stats
        self._store.record_queue_stats(
            pending=self._executor.pending_count,
            active=self._executor.active_count,
            max_workers=self._executor.max_workers,
        )
