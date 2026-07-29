#!/usr/bin/env bash
# scripts/download-models.sh
#
# Download the model weights required by Bishon V2.
#
# Two model sets:
#   1. Qwen3-Reranker-0.6B (~1.2 GB) — for in-process rerank.
#      Optional: only needed when RERANK_ENABLED=true (default false).
#   2. PaddleOCR v3 models (~100 MB) — for OCR on images/scanned PDFs.
#      Required if the deployment will ingest image or scanned-PDF content.
#
# Sources (China-friendly defaults):
#   - Qwen3-Reranker: HuggingFace China mirror (hf-mirror.com).
#                     Set HF_ENDPOINT to override.
#   - PaddleOCR:      PaddlePaddle official CDN (auto-downloaded by the
#                     paddleocr package on first use, requires bishon env).
#
# Usage:
#   bash scripts/download-models.sh                          # default: ./models
#   bash scripts/download-models.sh --target /opt/Bishon/V2/dev/models
#   bash scripts/download-models.sh --dry-run                # print URLs only
#   bash scripts/download-models.sh --offline <tar.gz>       # extract from tarball
#   bash scripts/download-models.sh --skip-rerank            # only PaddleOCR
#   bash scripts/download-models.sh --skip-paddleocr         # only Reranker
#
# Exit codes:
#   0  success (or --dry-run completed)
#   1  download or validation failure
#   2  usage error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/models"
DRY_RUN=false
OFFLINE_TAR=""
SKIP_RERANK=false
SKIP_PADDLEOCR=false

# Defaults — overridable via env for internal CI / custom mirrors.
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
RERANK_REPO="${RERANK_REPO:-Qwen/Qwen3-Reranker-0.6B}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        TARGET="$2";        shift 2 ;;
        --dry-run)       DRY_RUN=true;       shift ;;
        --offline)       OFFLINE_TAR="$2";   shift 2 ;;
        --skip-rerank)   SKIP_RERANK=true;   shift ;;
        --skip-paddleocr) SKIP_PADDLEOCR=true; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '[download-models] %s\n' "$*"; }
die()  { printf '[download-models] FATAL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TARGET"

# ============================================================================
# Offline mode: just extract a pre-built models tarball.
# ============================================================================
if [ -n "$OFFLINE_TAR" ]; then
    [ -f "$OFFLINE_TAR" ] || die "tarball not found: $OFFLINE_TAR"
    log "extracting $OFFLINE_TAR → $TARGET"
    tar -xzf "$OFFLINE_TAR" -C "$TARGET"
    log "done. Contents:"
    ls "$TARGET" | head -10
    exit 0
fi

# ============================================================================
# Online mode: download from configured sources.
# ============================================================================

# --- 1. Qwen3-Reranker from HuggingFace mirror --------------------------------
if ! $SKIP_RERANK; then
    RERANK_DIR="$TARGET/Qwen3-Reranker-0.6B"
    log "=== Qwen3-Reranker-0.6B → $RERANK_DIR ==="
    log "source: $HF_ENDPOINT/$RERANK_REPO"

    if [ -d "$RERANK_DIR" ] && [ -n "$(ls -A "$RERANK_DIR" 2>/dev/null)" ]; then
        # Idempotency: existing dir means no re-download (bandwidth-friendly).
        if $DRY_RUN; then
            log "(dry-run) $RERANK_DIR already populated — would skip"
        else
            log "$RERANK_DIR already populated — skipping (remove dir to force re-download)"
        fi
    elif $DRY_RUN; then
        log "(dry-run) would: git clone --depth 1 $HF_ENDPOINT/$RERANK_REPO $RERANK_DIR"
    else
        mkdir -p "$RERANK_DIR"
        # git clone --depth 1 pulls only the latest commit; much smaller than full history.
        # hf-mirror.com supports git protocol. If git fails, fall back to huggingface_hub.
        if git clone --depth 1 "${HF_ENDPOINT}/${RERANK_REPO}" "$RERANK_DIR" 2>&1 | sed 's/^/  /'; then
            rm -rf "$RERANK_DIR/.git"
            log "Reranker downloaded."
        else
            log "git clone failed; trying huggingface_hub Python lib..."
            BISHON_PY="${BISHON_PY:-/opt/miniconda3/envs/bishon/bin/python}"
            if [ -x "$BISHON_PY" ]; then
                HF_ENDPOINT="$HF_ENDPOINT" "$BISHON_PY" - <<PY
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="$RERANK_REPO",
    local_dir="$RERANK_DIR",
    resume_download=True,
)
PY
                log "Reranker downloaded via huggingface_hub."
            else
                die "git clone failed and $BISHON_PY not available."
            fi
        fi
    fi
fi

# --- 2. PaddleOCR models via paddleocr package -------------------------------
if ! $SKIP_PADDLEOCR; then
    PADDLE_DIR="$TARGET/paddleocr_models"
    log "=== PaddleOCR models → $PADDLE_DIR ==="
    log "source: PaddlePaddle CDN (auto-downloaded by paddleocr package on first use)"

    if $DRY_RUN; then
        log "(dry-run) would: trigger paddleocr auto-download via bishon env python"
    else
        BISHON_PY="${BISHON_PY:-/opt/miniconda3/envs/bishon/bin/python}"
        if [ ! -x "$BISHON_PY" ]; then
            cat >&2 <<EOF
[download-models] WARN: $BISHON_PY not found.
       PaddleOCR models are downloaded automatically on first OCR call
       inside the bishon conda env. To pre-populate, ensure the env is
       available and re-run this script, or trigger OCR once:
         conda activate bishon
         python -c "from paddleocr import PaddleOCR; PaddleOCR(use_angle_cls=True, lang='ch')"
       Models land in $PADDLE_DIR by default.
EOF
        else
            log "triggering paddleocr model auto-download..."
            cd "$REPO_ROOT"
            # The init_cfg flow in local_doc_qa.py sets the model dir explicitly;
            # mirror that here by setting the env var PADDLEOCR_HOME if needed.
            "$BISHON_PY" - <<'PY' 2>&1 | sed 's/^/  /' || log "paddleocr init warning (non-fatal)"
import os, sys
sys.path.insert(0, os.getcwd())
# Import side-effect triggers model download to models/paddleocr_models/.
from bishon_kernel.configs.model_config import root_path
ocr_dir = os.path.join(root_path, 'models', 'paddleocr_models')
os.makedirs(ocr_dir, exist_ok=True)
# PaddleOCR 3.x: PaddleOCR() init triggers downloads to the configured dir.
from paddleocr import PaddleOCR
PaddleOCR(use_angle_cls=True, lang='ch', ocr_version='PP-OCRv4')
print("paddleocr models ready")
PY
            log "paddleocr auto-download triggered."
        fi
    fi
fi

# --- 3. Validation -----------------------------------------------------------
log "=== Validation ==="
if ! $SKIP_RERANK; then
    if [ -f "$TARGET/Qwen3-Reranker-0.6B/model.safetensors" ]; then
        sz=$(stat -c %s "$TARGET/Qwen3-Reranker-0.6B/model.safetensors" 2>/dev/null || stat -f %z "$TARGET/Qwen3-Reranker-0.6B/model.safetensors")
        log "  Reranker model.safetensors: $((sz / 1024 / 1024)) MB ✓"
    else
        log "  Reranker model.safetensors: MISSING (Rerank will be unavailable)"
    fi
fi
if ! $SKIP_PADDLEOCR; then
    if [ -d "$TARGET/paddleocr_models" ]; then
        subdirs=$(find "$TARGET/paddleocr_models" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        log "  paddleocr_models subdirs: $subdirs (expected ≥4: det/rec/cls/doc_ori)"
    else
        log "  paddleocr_models: MISSING (OCR will be unavailable)"
    fi
fi

log "done. See docs/dev-environment.md for next steps."
