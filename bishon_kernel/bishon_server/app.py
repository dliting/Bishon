"""Bishon V2 — FastAPI main entry point (replaces Sanic)."""
import asyncio
import logging
import os
import sys

# Add the project root to sys.path
current_script_path = os.path.abspath(__file__)
current_dir = os.path.dirname(current_script_path)
parent_dir = os.path.dirname(current_dir)
root_dir = os.path.dirname(parent_dir)
sys.path.append(root_dir)

# Windows DLL compat: torch must be imported before paddle, otherwise CUDA libs conflict
from contextlib import asynccontextmanager  # noqa: E402

import torch  # noqa: F401, E402
from fastapi import FastAPI  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from fastapi.responses import JSONResponse  # noqa: E402
from fastapi.staticfiles import StaticFiles  # noqa: E402

from bishon_kernel.bishon_server.handler import _UserIdError, router  # noqa: E402
from bishon_kernel.core.local_doc_qa import LocalDocQA  # noqa: E402
from bishon_kernel.monitoring import (  # noqa: E402
    HealthChecker,
    ServiceStatusStore,
    TrackedExecutor,
)

def _read_app_version() -> str:
    """Read version from VERSION file at repo root. Avoids drift between
    VERSION file and /api/health endpoint."""
    version_path = os.path.join(root_dir, "VERSION")
    try:
        with open(version_path, "r", encoding="utf-8") as f:
            return f.read().strip() or "0.0.0-unknown"
    except OSError:
        return "0.0.0-unknown"


APP_VERSION = _read_app_version()

# Global instance
local_doc_qa: LocalDocQA = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """FastAPI lifespan manager (replaces Sanic's before_server_start)."""
    global local_doc_qa

    # Initialize core QA engine
    local_doc_qa = LocalDocQA()
    local_doc_qa.init_cfg()
    app.state.local_doc_qa = local_doc_qa

    # Initialize monitoring
    monitor_store = ServiceStatusStore()
    executor      = TrackedExecutor(max_workers=4)
    health_checker = HealthChecker(local_doc_qa, monitor_store, executor)

    app.state.monitor_store  = monitor_store
    app.state.executor       = executor
    app.state.health_checker = health_checker

    # Share monitor_store with LocalDocQA for record_outcome calls
    local_doc_qa.monitor_store = monitor_store

    await health_checker.start()
    logging.info("[SUCCESS] Bishon V2 知识库服务初始化完成")

    yield

    # Shutdown
    await health_checker.stop()
    health_checker.shutdown()
    executor.shutdown(wait=True)
    logging.info("[SHUTDOWN] Bishon V2 服务已停止")


app = FastAPI(
    title="Bishon V2",
    description="本地知识库问答系统",
    version=APP_VERSION,
    lifespan=lifespan,
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    allow_credentials=True,
)

# API router
app.include_router(router)


# Unified handler for user_id validation errors
@app.exception_handler(_UserIdError)
async def _user_id_error_handler(request, exc: _UserIdError):
    return JSONResponse(exc.body)

# Frontend static files (mounted only if dist exists)
dist_path = os.path.join(current_dir, 'dist', 'bishon')
if os.path.isdir(dist_path):
    app.mount('/bishon', StaticFiles(directory=dist_path, html=True), name='bishon')
    logging.info("[SUCCESS] 前端静态文件已挂载: /bishon/")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host='0.0.0.0', port=8777, log_level='info')
