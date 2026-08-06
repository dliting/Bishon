#!/bin/bash
# Bishon V2 startup script (Linux / WSL).
# Knowledge-base service — standalone launch.
#
# Usage: bash start.sh [--source-dir <path>] [--daemon]
#   --source-dir defaults to the project root (two levels up from this script).
#   --daemon      run in background (setsid nohup), log to <source-dir>/logs/backend.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_SOURCE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="$DEFAULT_SOURCE_DIR"
DAEMON=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --daemon) DAEMON=true; shift ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
cd "$SOURCE_DIR"

# Activate the conda environment.
CONDA_SH=""
for candidate in \
    "/opt/miniconda3/etc/profile.d/conda.sh" \
    "$HOME/miniconda3/etc/profile.d/conda.sh" \
    "/opt/anaconda3/etc/profile.d/conda.sh"; do
    if [ -f "$candidate" ]; then
        CONDA_SH="$candidate"
        break
    fi
done

if [ -n "$CONDA_SH" ]; then
    source "$CONDA_SH"
elif command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
else
    echo "[ERROR] Conda not found. Please install Miniconda/Anaconda first."
    exit 1
fi
conda activate bishon || {
    echo "[ERROR] Failed to activate conda env 'bishon'"
    exit 1
}

# Ensure log directories exist.
mkdir -p logs/debug_logs logs/qa_logs BISHON_DB/faiss BISHON_DB/content

# Pre-set tiktoken cache directory so offline deployments work.
export TIKTOKEN_CACHE_DIR="$SOURCE_DIR/models/tiktoken_cache"

# Install dependencies (first run only).
if [ ! -f ".deps_installed" ]; then
    echo "[INFO] Installing Python dependencies..."
    pip install -r requirements.txt && touch .deps_installed || {
        echo "[ERROR] pip install failed. Run manually: pip install -r requirements.txt"
        exit 1
    }
fi

# Kill any process already bound to port 8777.
PID=""
if command -v lsof &>/dev/null; then
    PID=$(lsof -ti :8777 2>/dev/null || true)
elif command -v ss &>/dev/null; then
    PID=$(ss -tlnp 'sport = :8777' 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)
elif command -v fuser &>/dev/null; then
    PID=$(fuser 8777/tcp 2>/dev/null || true)
fi
if [ -n "$PID" ]; then
    echo "[INFO] Port 8777 is in use by PID $PID, killing..."
    kill -9 $PID 2>/dev/null || true
    sleep 2
fi

echo "[INFO] Starting Bishon V2 on http://localhost:8777 ..."
echo ""
echo "  日志:"
echo "    应用:  tail -f logs/debug_logs/debug.log"
echo "    问答:  tail -f logs/qa_logs/qa.log"
echo ""
echo "  停止: Ctrl+C 或 kill \$(fuser 8777/tcp 2>/dev/null)"
echo ""
if $DAEMON; then
    mkdir -p logs
    setsid nohup uvicorn bishon_kernel.bishon_server.app:app --host 0.0.0.0 --port 8777 --log-level info \
        > logs/backend.log 2>&1 < /dev/null &
    echo "[INFO] Backend started in background (pid $!). Logs: logs/backend.log"
    echo "[INFO] Stop: kill $(pgrep -f 'uvicorn bishon_kernel' | head -1)"
else
    exec uvicorn bishon_kernel.bishon_server.app:app --host 0.0.0.0 --port 8777 --log-level info
fi
