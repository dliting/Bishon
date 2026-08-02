#!/usr/bin/env bash
# scripts/common/download-models.sh
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
#   bash scripts/common/download-models.sh                          # default: ./models
#   bash scripts/common/download-models.sh --target /opt/Bishon/V2/dev/models
#   bash scripts/common/download-models.sh --dry-run                # print URLs only
#   bash scripts/common/download-models.sh --offline <tar.gz>       # extract from tarball
#   bash scripts/common/download-models.sh --skip-rerank            # only PaddleOCR
#   bash scripts/common/download-models.sh --skip-paddleocr         # only Reranker
#
# Exit codes:
#   0  success (or --dry-run completed)
#   1  download or validation failure
#   2  usage error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
# paddleocr >=3.7 downloads PP-OCRv6_medium models into the paddlex cache
# (~/.paddlex/official_models/), NOT into models/paddleocr_models/ — the app
# reads model_dir explicitly. So after triggering the download we copy the
# cached models into the app layout (det/rec/cls/doc_ori), same as local_doc_qa
# expects. Model source: set PADDLE_PDX_MODEL_SOURCE=hf (HuggingFace) or
# modelscope (default) to choose the mirror.
if ! $SKIP_PADDLEOCR; then
    PADDLE_DIR="$TARGET/paddleocr_models"
    log "=== PaddleOCR models (PP-OCRv6_medium) → $PADDLE_DIR ==="
    log "source: paddlex official models (modelscope/HuggingFace), see PADDLE_PDX_MODEL_SOURCE"

    if $DRY_RUN; then
        log "(dry-run) would: trigger paddleocr PP-OCRv6_medium download and copy to $PADDLE_DIR"
    else
        BISHON_PY="${BISHON_PY:-/opt/miniconda3/envs/bishon/bin/python}"
        if [ ! -x "$BISHON_PY" ]; then
            cat >&2 <<EOF
[download-models] WARN: $BISHON_PY not found.
       PaddleOCR models are downloaded automatically on first OCR call
       inside the bishon conda env. To pre-populate, ensure the env is
       available and re-run this script, or trigger OCR once:
         conda activate bishon
         python -c "from paddleocr import PaddleOCR; PaddleOCR(text_detection_model_name='PP-OCRv6_medium_det', text_recognition_model_name='PP-OCRv6_medium_rec')"
       Models land in $PADDLE_DIR by default.
EOF
        else
            log "triggering paddleocr PP-OCRv6_medium download..."
            cd "$REPO_ROOT"
            "$BISHON_PY" - <<'PY' 2>&1 | sed 's/^/  /' || log "paddleocr init warning (non-fatal)"
from paddleocr import PaddleOCR
PaddleOCR(
    text_detection_model_name="PP-OCRv6_medium_det",
    text_recognition_model_name="PP-OCRv6_medium_rec",
    use_doc_orientation_classify=True,
    use_doc_unwarping=False,
)
print("paddleocr models ready")
PY
            PADDLEX_CACHE="$HOME/.paddlex/official_models"
            log "copying cached models into $PADDLE_DIR ..."
            mkdir -p "$PADDLE_DIR/det" "$PADDLE_DIR/rec" "$PADDLE_DIR/cls" "$PADDLE_DIR/doc_ori"
            cp "$PADDLEX_CACHE/PP-OCRv6_medium_det/"*    "$PADDLE_DIR/det/"
            cp "$PADDLEX_CACHE/PP-OCRv6_medium_rec/"*    "$PADDLE_DIR/rec/"
            cp "$PADDLEX_CACHE/PP-LCNet_x1_0_textline_ori/"* "$PADDLE_DIR/cls/"
            cp "$PADDLEX_CACHE/PP-LCNet_x1_0_doc_ori/"*  "$PADDLE_DIR/doc_ori/"
            rm -f "$PADDLE_DIR/cls/img_textline180_demo_res."* "$PADDLE_DIR/det/README.md"
            log "paddleocr models copied (det/rec/cls/doc_ori)."
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
