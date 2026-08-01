# System Health Monitoring Design

## Context

Bishon V2's current `/api/health` endpoint only returns `{"status": "ok", "version": "2.0.0"}` with no actual service verification. Operators have no visibility into whether LLM, Embedding, OCR, or other services are functioning, nor can they see request queue backlog. This design adds comprehensive health monitoring with a dedicated frontend page.

## Requirements

- Enhanced `/api/health` returning detailed per-service status
- Independent monitoring page at `/#/monitor` (no main layout)
- Background periodic check every 60 seconds + update on business call success/failure
- Track ThreadPoolExecutor queue depth (pending tasks)
- No user_id required for health endpoint

## Architecture

### New Package: `bishon_kernel/monitoring/`

Four modules:

```
bishon_kernel/monitoring/
    __init__.py          # exports HealthChecker, status_store, TrackedExecutor
    status_store.py      # thread-safe ServiceStatus store
    service_probes.py    # lightweight per-service health probes
    health_checker.py    # periodic check orchestrator
    tracked_executor.py  # ThreadPoolExecutor wrapper with queue tracking
```

### Data Model

```python
@dataclass
class ServiceStatus:
    name: str                    # "llm", "embedding", "rerank", "ocr", "faiss", "sqlite"
    status: str                  # "healthy" | "unhealthy" | "unknown" | "disabled"
    detail: str                  # e.g. "Ollama qwen3:8b @ localhost:11434"
    last_check: float            # unix timestamp
    last_success: float | None   # unix timestamp of last successful check/call
    latency_ms: float | None     # most recent check latency
```

### API Response Format

`GET /api/health` returns:

```json
{
  "status": "ok",
  "version": "2.1.0",
  "uptime_seconds": 3600,
  "services": {
    "llm": {
      "status": "healthy",
      "detail": "Ollama qwen3:8b @ localhost:11434",
      "last_check": 1722500000.0,
      "last_success": 1722500000.0,
      "latency_ms": 45.2
    },
    "embedding": { "status": "healthy", "detail": "qwen3-embedding:0.6b", "latency_ms": 32.1, ... },
    "rerank":    { "status": "disabled", "detail": "RERANK_ENABLED=false", ... },
    "ocr":       { "status": "healthy", "detail": "PaddleOCR GPU", ... },
    "faiss":     { "status": "healthy", "detail": "1024-dim, 3 collections", ... },
    "sqlite":    { "status": "healthy", "detail": "BISHON_DB/bishon.db", ... }
  },
  "queue": {
    "pending_tasks": 2,
    "max_workers": 4,
    "active_tasks": 3
  }
}
```

Top-level `status` is `"ok"` if all non-disabled services are healthy, `"degraded"` if any is unhealthy.

## Module Details

### 1. `status_store.py` — ServiceStatusStore

Thread-safe status store, stored on `app.state.monitor_store` and accessed via `request.app.state.monitor_store`.

Key methods:
- `get_all() -> dict` — snapshot of all service statuses
- `get(name) -> ServiceStatus` — single service
- `record_outcome(name, success, detail, latency_ms)` — update from business call or probe
- `record_queue_stats(pending, active, max_workers)` — update queue info

Uses `threading.Lock` for thread safety. Initialized with all services in `"unknown"` state.

### 2. `service_probes.py` — Probe Functions

Each probe is a standalone function returning `(success: bool, detail: str, latency_ms: float)`.

| Service | Probe | Rationale |
|---------|-------|-----------|
| LLM (Ollama) | `GET {base_url}/api/tags` | Lightweight, no token consumption |
| LLM (OpenAI/MiniMax) | `GET {base_url}/v1/models` | List models, no token consumption |
| Embedding | `GET {base_url}/v1/models` | Check service reachability |
| Rerank | Check `enabled` flag + model path exists | Pure state check, no model loading |
| OCR | Check `ocr_engine is not None` | Pure state check |
| FAISS | Check `len(faiss_kbs)` and dimension | Pure state check |
| SQLite | `SELECT 1` | Lightweight query |

Probes receive `LocalDocQA` instance and env config as arguments. Network probes use `httpx` with a short timeout (5 seconds).

### 3. `health_checker.py` — HealthChecker

Orchestrates periodic background checks.

```python
class HealthChecker:
    def __init__(self, local_doc_qa: LocalDocQA, store: ServiceStatusStore):
        ...
    async def start(self):
        """Start periodic check loop (called from FastAPI lifespan)."""
    async def stop(self):
        """Cancel the background task."""
    async def _periodic_check(self):
        """Run all probes every CHECK_INTERVAL_SECONDS, update store."""
```

- `CHECK_INTERVAL_SECONDS = 60` (constant)
- Probes run in a separate executor to avoid blocking the event loop
- On startup, runs an immediate check before entering the loop
- Records queue stats from `TrackedExecutor` on each cycle

### 4. `tracked_executor.py` — TrackedExecutor

Drop-in replacement for `ThreadPoolExecutor`:

```python
class TrackedExecutor(ThreadPoolExecutor):
    def __init__(self, max_workers, ...):
        super().__init__(max_workers=max_workers, ...)
        self._pending_count   = 0
        self._active_count    = 0
        self._lock            = threading.Lock()

    def submit(self, fn, *args, **kwargs):
        # Increment _pending_count, add done-callback to decrement
        ...

    @property
    def pending_count(self) -> int: ...
    @property
    def active_count(self) -> int: ...
```

Overrides `submit()` to track pending tasks via counter + done-callback. Thread-safe with `threading.Lock`.

Tracking logic:
- `submit()`: increment `_pending_count`, wrap the future with a callback that decrements `_pending_count` and increments `_active_count` when the task starts (via `running()` state check), and decrements `_active_count` on completion.
- Since ThreadPoolExecutor doesn't expose a "task started" callback, we use a wrapper function: the wrapper first decrements `_pending_count` and increments `_active_count`, then calls the original function. The done-callback decrements `_active_count`.

## Integration Points

### `handler.py` Changes

1. Replace `_executor = ThreadPoolExecutor(max_workers=4)` with `_executor = TrackedExecutor(max_workers=4)`
2. Enhance `health_check()` endpoint to return full status from `status_store`
3. Add `record_outcome()` calls:
   - After LLM call in `local_doc_chat` (success/failure)
   - After embedding call in `upload_files` flow (via `local_doc_qa.insert_files_to_milvus`)

### `app.py` Changes

In lifespan:
1. Create `ServiceStatusStore` and `HealthChecker`
2. Store them on `app.state`
3. Start `HealthChecker` as `asyncio.create_task`
4. On shutdown, call `health_checker.stop()` and `executor.shutdown(wait=True)`

### `local_doc_qa.py` Changes

Add `record_outcome` calls for embedding and FAISS operations in `insert_files_to_milvus`:
- After `local_file.create_embedding()` success/failure → `record_outcome("embedding", ...)`
- After `faiss_kb.insert_files()` success/failure → `record_outcome("faiss", ...)`

## Frontend: Monitor Page

### Route

Add to `front_end/src/router/routes.ts`:

```typescript
{
  path: '/monitor',
  name: 'monitor',
  component: () => import('@/views/Monitor.vue'),
  meta: { title: '系统监控' },
}
```

This is a top-level route (not a child of the main layout), so it renders without Sider/Head.

### Page: `front_end/src/views/Monitor.vue`

Layout:
- Header bar with title "Bishon 系统监控" and auto-refresh indicator
- Service status cards in a grid (2 columns)
  - Each card shows: service name, status indicator (green/red/gray dot), detail, latency, last check time
- Queue section: pending/active/max workers with a simple bar visualization
- System info: version, uptime

Uses raw `fetch('/api/health')` — no user_id, no axios interceptor needed.
Auto-refresh every 30 seconds with a visible countdown.
Matches existing project style (Ant Design Vue components, dark header theme).

## Testing

### Unit Tests

- `test_status_store.py`: thread-safety, record_outcome, get_all
- `test_service_probes.py`: mock httpx/openai responses, verify probe results
- `test_tracked_executor.py`: submit tasks, verify pending/active counts
- `test_health_checker.py`: periodic loop timing, probe orchestration

### Integration Tests

- `test_api_health.py`: enhanced `/api/health` response format validation
- Verify `record_outcome` integration in chat/upload flows

### Frontend Test

- Playwright: navigate to `/#/monitor`, verify page renders, verify auto-refresh

## Files to Create/Modify

| File | Action |
|------|--------|
| `bishon_kernel/monitoring/__init__.py` | Create |
| `bishon_kernel/monitoring/status_store.py` | Create |
| `bishon_kernel/monitoring/service_probes.py` | Create |
| `bishon_kernel/monitoring/health_checker.py` | Create |
| `bishon_kernel/monitoring/tracked_executor.py` | Create |
| `bishon_kernel/bishon_server/handler.py` | Modify |
| `bishon_kernel/bishon_server/app.py` | Modify |
| `bishon_kernel/core/local_doc_qa.py` | Modify |
| `front_end/src/router/routes.ts` | Modify |
| `front_end/src/views/Monitor.vue` | Create |
| `docs/API.md` | Modify |
| `tests/backend/unit/monitoring/` | Create (test files) |

## Verification

1. Start server: `python -m bishon_kernel.bishon_server.app`
2. `curl http://localhost:8777/api/health` — verify enhanced response with all services
3. Stop Ollama, wait 60s, check health — LLM should show "unhealthy"
4. Restart Ollama, make a chat request — LLM should flip back to "healthy"
5. Open `http://localhost:8777/bishon/#/monitor` — verify monitoring page renders
6. Run `bash run_all_tests.sh` — all tests pass
