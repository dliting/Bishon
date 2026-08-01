"""Thread-safe store for service health statuses."""
import logging
import threading
import time
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Service name constants
SERVICE_LLM       = "llm"
SERVICE_EMBEDDING = "embedding"
SERVICE_RERANK    = "rerank"
SERVICE_OCR       = "ocr"
SERVICE_FAISS     = "faiss"
SERVICE_SQLITE    = "sqlite"

ALL_SERVICES = [
    SERVICE_LLM,
    SERVICE_EMBEDDING,
    SERVICE_RERANK,
    SERVICE_OCR,
    SERVICE_FAISS,
    SERVICE_SQLITE,
]

# Status value constants
STATUS_HEALTHY   = "healthy"
STATUS_UNHEALTHY = "unhealthy"
STATUS_UNKNOWN   = "unknown"
STATUS_DISABLED  = "disabled"


@dataclass
class ServiceStatus:
    """Health status of a single service."""

    name: str
    status: str                    = STATUS_UNKNOWN
    detail: str                    = ""
    last_check: float              = 0.0
    last_success: float | None     = None
    latency_ms: float | None       = None

    def to_dict(self) -> dict:
        """Serialize to API response dict."""
        return {
            "status":      self.status,
            "detail":      self.detail,
            "last_check":  self.last_check,
            "last_success": self.last_success,
            "latency_ms":  self.latency_ms,
        }


@dataclass
class QueueStats:
    """Snapshot of the task executor queue."""

    pending_tasks: int = 0
    active_tasks:  int = 0
    max_workers:   int = 0

    def to_dict(self) -> dict:
        return {
            "pending_tasks": self.pending_tasks,
            "active_tasks":  self.active_tasks,
            "max_workers":   self.max_workers,
        }


class ServiceStatusStore:
    """Thread-safe store for all service health statuses.

    Stored on ``app.state.monitor_store`` and accessed via
    ``request.app.state.monitor_store``.
    """

    def __init__(self):
        self._services: dict[str, ServiceStatus] = {
            name: ServiceStatus(name=name) for name in ALL_SERVICES
        }
        self._queue: QueueStats = QueueStats()
        self._lock = threading.Lock()
        self._start_time: float = time.time()

    @property
    def start_time(self) -> float:
        """Server start time (unix timestamp)."""
        return self._start_time

    def get(self, name: str) -> ServiceStatus:
        """Get a single service status (returns a copy)."""
        with self._lock:
            svc = self._services.get(name)
            if svc is None:
                raise KeyError(f"Unknown service: {name}")
            return ServiceStatus(
                name=svc.name, status=svc.status, detail=svc.detail,
                last_check=svc.last_check, last_success=svc.last_success,
                latency_ms=svc.latency_ms,
            )

    def get_all(self) -> dict[str, ServiceStatus]:
        """Get a snapshot of all service statuses."""
        with self._lock:
            return {
                name: ServiceStatus(
                    name=s.name, status=s.status, detail=s.detail,
                    last_check=s.last_check, last_success=s.last_success,
                    latency_ms=s.latency_ms,
                )
                for name, s in self._services.items()
            }

    def record_outcome(
        self,
        name: str,
        success: bool,
        detail: str | None = None,
        latency_ms: float | None = None,
    ) -> None:
        """Update a service's status from a business call result.

        Args:
            name: Service name constant (e.g. SERVICE_LLM).
            success: Whether the operation succeeded.
            detail: Human-readable detail string. None preserves the previous value.
            latency_ms: Operation latency in milliseconds, if available.
        """
        self.record_probe(name, STATUS_HEALTHY if success else STATUS_UNHEALTHY, detail, latency_ms)

    def record_probe(
        self,
        name: str,
        status: str,
        detail: str | None = None,
        latency_ms: float | None = None,
    ) -> None:
        """Update a service's status from a probe result.

        Args:
            name: Service name constant (e.g. SERVICE_LLM).
            status: Status constant (STATUS_HEALTHY, STATUS_UNHEALTHY, STATUS_DISABLED).
            detail: Human-readable detail string. None preserves the previous value.
            latency_ms: Probe latency in milliseconds, if available.
        """
        now = time.time()
        with self._lock:
            svc = self._services.get(name)
            if svc is None:
                logger.warning("record_probe: unknown service %s", name)
                return
            svc.status      = status
            svc.last_check  = now
            if status == STATUS_HEALTHY:
                svc.last_success = now
            if detail is not None:
                svc.detail = detail
            if latency_ms is not None:
                svc.latency_ms = latency_ms
            logger.info(
                "record_probe: %s → %s (%s, %.1fms)",
                name, svc.status, detail, latency_ms or -1,
            )

    def record_queue_stats(
        self, pending: int, active: int, max_workers: int,
    ) -> None:
        """Update the executor queue snapshot."""
        with self._lock:
            self._queue.pending_tasks = pending
            self._queue.active_tasks  = active
            self._queue.max_workers   = max_workers

    def get_queue_stats(self) -> QueueStats:
        """Get a copy of the queue stats."""
        with self._lock:
            return QueueStats(
                pending_tasks=self._queue.pending_tasks,
                active_tasks=self._queue.active_tasks,
                max_workers=self._queue.max_workers,
            )

    def to_api_dict(self, version: str) -> dict:
        """Produce the full API response dict for ``GET /api/health``."""
        with self._lock:
            services_snapshot = {
                name: svc.to_dict() for name, svc in self._services.items()
            }
            queue_snapshot = self._queue.to_dict()
            uptime = time.time() - self._start_time

        # Determine overall status
        overall = "ok"
        for svc_dict in services_snapshot.values():
            if svc_dict["status"] == STATUS_UNHEALTHY:
                overall = "degraded"
                break

        return {
            "status":         overall,
            "version":        version,
            "uptime_seconds": round(uptime, 1),
            "services":       services_snapshot,
            "queue":          queue_snapshot,
        }
