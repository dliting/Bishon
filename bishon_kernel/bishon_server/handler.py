"""Bishon V2 API Handlers — FastAPI version, preserves the Sanic-era API contract verbatim."""
import asyncio
import json
import logging
import os
import re
import traceback
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import (
    FileResponse,
    JSONResponse,
    PlainTextResponse,
    RedirectResponse,
    StreamingResponse,
)

from bishon_kernel.connector.llm.adapters.base import SSE_DATA_PREFIX_LEN
from bishon_kernel.core.local_doc_qa import LocalDocQA
from bishon_kernel.core.local_file import LocalFile
from bishon_kernel.utils.custom_log import debug_logger, qa_logger
from bishon_kernel.utils.general_utils import (
    current_timestamp,
    format_source_documents,
    get_invalid_user_id_msg,
    truncate_filename,
    validate_user_id,
)

# Thread pool for offloading synchronous LLM/FAISS operations
_executor = ThreadPoolExecutor(max_workers=4)
# Sentinel for safe generator exhaustion (avoids StopIteration in executor)
_GEN_SENTINEL = object()

# API response codes (contract with frontend)
CODE_SUCCESS          = 200
CODE_KB_NOT_FOUND     = 2001
CODE_INVALID_INPUT    = 2002
CODE_KB_MISSING       = 2003
CODE_FILE_NOT_FOUND   = 2004
CODE_INVALID_USER     = 2005
CODE_LLM_ERROR        = 500

router = APIRouter(prefix="/api")


class _UserIdError(Exception):
    """Carries an error response body during request validation; returned by the app-level exception handler."""
    def __init__(self, body: dict):
        self.body = body


def _get_local_doc_qa(request: Request) -> LocalDocQA:
    return request.app.state.local_doc_qa


async def _parse_user_request(request: Request) -> tuple[str, dict]:
    """Parse the request body, extract and validate user_id. Returns (user_id, body)."""
    body = await request.json()
    user_id = body.get('user_id')
    if user_id is None:
        raise _UserIdError({"code": CODE_INVALID_INPUT, "msg": '输入非法！request.json：' + str(body) + '，请检查！'})
    if not validate_user_id(user_id):
        raise _UserIdError({"code": CODE_INVALID_USER, "msg": get_invalid_user_id_msg(user_id=user_id)})
    return user_id, body


@router.get("/health")
async def health_check():
    return {"status": "ok", "version": "2.0.0"}


@router.get("/local_doc_qa/download_file/{file_id}")
async def download_file(file_id: str, request: Request):
    """Download the original file by file_id; the browser previews or downloads it. URL-type files return a 302 redirect."""
    local_doc_qa = _get_local_doc_qa(request)
    debug_logger.info("download_file %s", file_id)

    if len(file_id) != 32 or not all(c in '0123456789abcdef' for c in file_id):
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": "file not found"}, status_code=404)

    rows = local_doc_qa.kb_manager.get_file_download_info(file_id)
    if not rows:
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": "file not found"}, status_code=404)

    user_id, file_name, deleted = rows[0]
    if deleted:
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": "file deleted"}, status_code=404)

    if file_name and file_name.startswith("http"):
        return RedirectResponse(url=file_name, status_code=302)

    if '..' in file_name or '/' in file_name or '\\' in file_name:
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": "invalid file name"}, status_code=404)

    from bishon_kernel.configs.model_config import UPLOAD_ROOT_PATH
    file_path = os.path.join(UPLOAD_ROOT_PATH, user_id, file_id, file_name)
    if not os.path.isfile(file_path):
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": "file not found on disk"}, status_code=404)

    return FileResponse(file_path)


@router.get("/docs")
async def document():
    """API documentation."""
    description = """
# Bishon V2 API 接口

本地知识库问答系统，支持任意格式文件的上传和问答。
支持格式: PDF, Word(docx), PPT, TXT, 图片(jpg/png/jpeg), 网页链接, CSV, Excel, EML, Markdown
详细接口文档请参见 docs/API.md

# 接口列表
    POST /api/local_doc_qa/new_knowledge_base    — 新建知识库
    POST /api/local_doc_qa/upload_files           — 上传文件
    POST /api/local_doc_qa/upload_weblink         — 上传网页链接
    POST /api/local_doc_qa/local_doc_chat         — 问答接口（支持流式SSE）
    POST /api/local_doc_qa/list_knowledge_base    — 知识库列表
    POST /api/local_doc_qa/list_files             — 文件列表
    POST /api/local_doc_qa/get_total_status       — 获取状态
    POST /api/local_doc_qa/clean_files_by_status  — 清理文件
    POST /api/local_doc_qa/delete_files           — 删除文件
    POST /api/local_doc_qa/delete_knowledge_base  — 删除知识库
    POST /api/local_doc_qa/rename_knowledge_base  — 重命名知识库
     GET /api/local_doc_qa/download_file/{file_id} — 下载原始文件（文档溯源）
"""
    return PlainTextResponse(description)


@router.post("/local_doc_qa/new_knowledge_base")
async def new_knowledge_base(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("new_knowledge_base %s", user_id)
    kb_name = body.get('kb_name')
    kb_id = 'KB' + uuid.uuid4().hex
    local_doc_qa.create_milvus_collection(user_id, kb_id, kb_name)
    timestamp = current_timestamp()
    return JSONResponse({
        "code": CODE_SUCCESS, "msg": f"success create knowledge base {kb_id}",
        "data": {"kb_id": kb_id, "kb_name": kb_name, "timestamp": timestamp}
    })


@router.post("/local_doc_qa/upload_weblink")
async def upload_weblink(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("upload_weblink %s", user_id)
    kb_id = body.get('kb_id')
    url = body.get('url')
    mode = body.get('mode', 'soft')
    if not url:
        return JSONResponse({"code": CODE_INVALID_INPUT, "msg": "url 不能为空"})
    not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, [kb_id])
    if not_exist_kb_ids:
        msg = f"invalid kb_id: {not_exist_kb_ids}, please check..."
        return JSONResponse({"code": CODE_KB_NOT_FOUND, "msg": msg, "data": [{}]})
    timestamp = current_timestamp()
    exist_files = []
    if mode == 'soft':
        exist_files = local_doc_qa.kb_manager.check_file_exist_by_name(user_id, kb_id, [url])
    if exist_files:
        file_id, file_name, file_size, status = exist_files[0]
        msg = 'warning，当前的mode是soft，无法上传同名文件，如果想强制上传同名文件，请设置mode：strong'
        data = [{"file_id": file_id, "file_name": url, "status": status, "bytes": file_size, "timestamp": timestamp}]
    else:
        file_id, msg = local_doc_qa.kb_manager.add_file(user_id, kb_id, url, timestamp)
        local_file = LocalFile(user_id, kb_id, url, file_id, url, local_doc_qa.embeddings, is_url=True)
        data = [{"file_id": file_id, "file_name": url, "status": "gray", "bytes": 0, "timestamp": timestamp}]
        loop = asyncio.get_running_loop()
        loop.run_in_executor(_executor, local_doc_qa.insert_files_to_milvus, user_id, kb_id, [local_file])
        msg = "success，后台正在飞速上传文件，请耐心等待"
    return JSONResponse({"code": CODE_SUCCESS, "msg": msg, "data": data})


@router.post("/local_doc_qa/upload_files")
async def upload_files(
    request: Request,
    files: list[UploadFile] = File(...),
    user_id: str = Form(...),
    kb_id: str = Form(...),
    mode: str = Form('soft'),
    use_local_file: str = Form('false'),  # noqa: F841 — V1 API compat parameter
):
    local_doc_qa = _get_local_doc_qa(request)
    # upload_files uses Form parameters (not a JSON body), so _parse_user_request does not apply.
    if not user_id:
        return JSONResponse({"code": CODE_INVALID_INPUT, "msg": '输入非法！请检查！'})
    if not validate_user_id(user_id):
        return JSONResponse({"code": CODE_INVALID_USER, "msg": get_invalid_user_id_msg(user_id=user_id)})
    debug_logger.info("upload_files %s", user_id)
    debug_logger.info("mode: %s", mode)

    not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, [kb_id])
    if not_exist_kb_ids:
        msg = f"invalid kb_id: {not_exist_kb_ids}, please check..."
        return JSONResponse({"code": CODE_KB_NOT_FOUND, "msg": msg, "data": [{}]})

    data = []
    local_files = []
    file_names = []

    for file in files:
        if not file.filename:
            continue
        file_name = urllib.parse.unquote(file.filename, encoding='UTF-8')
        debug_logger.info('decode name: %s', file_name)
        file_name = re.sub(r'[\uFF01-\uFF5E\u3000-\u303F]', '', file_name)
        file_name = file_name.replace("/", "_")
        debug_logger.info('cleaned name: %s', file_name)
        file_name = truncate_filename(file_name)
        file_names.append(file_name)

    exist_file_names = []
    if mode == 'soft':
        exist_files = local_doc_qa.kb_manager.check_file_exist_by_name(user_id, kb_id, file_names)
        exist_file_names = [f[1] for f in exist_files]

    timestamp = current_timestamp()

    from bishon_kernel.configs.model_config import UPLOAD_ROOT_PATH

    for file, file_name in zip(files, file_names):
        if file_name in exist_file_names:
            continue
        file_content = await file.read()
        file_id, msg = local_doc_qa.kb_manager.add_file(user_id, kb_id, file_name, timestamp)
        debug_logger.info("file added: %s, %s, %s", file_name, file_id, msg)

        # Save to disk
        upload_dir = os.path.join(UPLOAD_ROOT_PATH, user_id, file_id)
        os.makedirs(upload_dir, exist_ok=True)
        file_path = os.path.join(upload_dir, file_name)
        with open(file_path, "wb+") as f:
            f.write(file_content)

        local_file = LocalFile(user_id, kb_id, file_path, file_id, file_name, local_doc_qa.embeddings)
        local_files.append(local_file)
        local_doc_qa.kb_manager.update_file_size(file_id, len(file_content))
        data.append({
            "file_id": file_id, "file_name": file_name, "status": "gray",
            "bytes": len(file_content), "timestamp": timestamp
        })

    loop = asyncio.get_running_loop()

    def _safe_insert(user_id, kb_id, local_files):
        try:
            local_doc_qa.insert_files_to_milvus(user_id, kb_id, local_files)
        except Exception:
            logging.error("Background insert_files_to_milvus error: %s", traceback.format_exc())
            debug_logger.error("Background insert_files_to_milvus error: %s", traceback.format_exc())
            for lf in local_files:
                try:
                    local_doc_qa.kb_manager.update_file_status(lf.file_id, 'red')
                except Exception:
                    debug_logger.error("Failed to update status for file %s", lf.file_id)

    loop.run_in_executor(_executor, _safe_insert, user_id, kb_id, local_files)
    if exist_file_names:
        msg = f'warning，当前的mode是soft，无法上传同名文件{exist_file_names}，如果想强制上传同名文件，请设置mode：strong'
    else:
        msg = "success，后台正在飞速上传文件，请耐心等待"
    return JSONResponse({"code": CODE_SUCCESS, "msg": msg, "data": data})


@router.post("/local_doc_qa/list_knowledge_base")
async def list_kbs(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("list_kbs %s", user_id)
    kb_infos = local_doc_qa.kb_manager.get_knowledge_bases(user_id)
    data = [{"kb_id": kb[0], "kb_name": kb[1]} for kb in kb_infos]
    debug_logger.info("all kb infos: %s", data)
    return JSONResponse({"code": CODE_SUCCESS, "data": data})


@router.post("/local_doc_qa/list_files")
async def list_docs(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("list_docs %s", user_id)
    kb_id = body.get('kb_id')
    debug_logger.info("kb_id: %s", kb_id)
    data = []
    file_infos = local_doc_qa.kb_manager.get_files(user_id, kb_id)
    status_count = {}
    msg_map = {
        'gray': "正在上传中，请耐心等待",
        'red': "文件处理失败，请检查文件类型（支持md/txt/pdf/jpg/png/jpeg/docx/xlsx/pptx/eml/csv），图片和PDF需要PaddleOCR支持",
        'yellow': "faiss插入失败，请稍后再试",
        'green': "上传成功"
    }
    for fi in file_infos:
        status = fi[2]
        status_count[status] = status_count.get(status, 0) + 1
        data.append({
            "file_id": fi[0], "file_name": fi[1], "status": fi[2], "bytes": fi[3],
            "content_length": fi[4], "timestamp": fi[5], "msg": msg_map.get(fi[2], '')
        })
    return JSONResponse({"code": CODE_SUCCESS, "msg": "success", "data": {'total': status_count, 'details': data}})


@router.post("/local_doc_qa/delete_knowledge_base")
async def delete_knowledge_base(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("delete_knowledge_base %s", user_id)
    kb_ids = body.get('kb_ids')
    if not kb_ids:
        raise _UserIdError({"code": CODE_INVALID_INPUT, "msg": "kb_ids 不能为空"})
    not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, kb_ids)
    if not_exist_kb_ids:
        return JSONResponse({"code": CODE_KB_MISSING, "msg": f"fail, knowledge Base {not_exist_kb_ids} not found"})

    faiss_kb = local_doc_qa.match_milvus_kb(user_id, kb_ids)
    for kb_id in kb_ids:
        faiss_kb.delete_partition(kb_id)
    local_doc_qa.kb_manager.delete_knowledge_base(user_id, kb_ids)
    return JSONResponse({"code": CODE_SUCCESS, "msg": f"Knowledge Base {kb_ids} delete success"})


@router.post("/local_doc_qa/rename_knowledge_base")
async def rename_knowledge_base(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("rename_knowledge_base %s", user_id)
    kb_id = body.get('kb_id')
    new_kb_name = body.get('new_kb_name')
    not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, [kb_id])
    if not_exist_kb_ids:
        return JSONResponse({"code": CODE_KB_MISSING, "msg": f"fail, knowledge Base {not_exist_kb_ids[0]} not found"})
    local_doc_qa.kb_manager.rename_knowledge_base(user_id, kb_id, new_kb_name)
    return JSONResponse({"code": CODE_SUCCESS, "msg": f"Knowledge Base {kb_id} rename success"})


@router.post("/local_doc_qa/delete_files")
async def delete_docs(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info("delete_docs %s", user_id)
    kb_id = body.get('kb_id')
    file_ids = body.get("file_ids")
    if not file_ids:
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": "file_ids 不能为空"})
    not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, [kb_id])
    if not_exist_kb_ids:
        return JSONResponse({"code": CODE_KB_MISSING, "msg": f"fail, knowledge Base {not_exist_kb_ids[0]} not found"})
    valid_file_infos = local_doc_qa.kb_manager.check_file_exist(user_id, kb_id, file_ids)
    if len(valid_file_infos) == 0:
        return JSONResponse({"code": CODE_FILE_NOT_FOUND, "msg": f"fail, files {file_ids} not found"})
    faiss_kb = local_doc_qa.match_milvus_kb(user_id, [kb_id])
    faiss_kb.delete_files(file_ids)
    local_doc_qa.kb_manager.delete_files(kb_id, file_ids)
    return JSONResponse({"code": CODE_SUCCESS, "msg": f"documents {file_ids} delete success"})


@router.post("/local_doc_qa/get_total_status")
async def get_total_status(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info('get_total_status %s', user_id)
    kbs = local_doc_qa.kb_manager.get_knowledge_bases(user_id)
    res = {}
    for kb_id, kb_name in kbs:
        gray   = local_doc_qa.kb_manager.get_file_by_status([kb_id], 'gray')
        red    = local_doc_qa.kb_manager.get_file_by_status([kb_id], 'red')
        yellow = local_doc_qa.kb_manager.get_file_by_status([kb_id], 'yellow')
        green  = local_doc_qa.kb_manager.get_file_by_status([kb_id], 'green')
        res[kb_name + kb_id] = {
            'green': len(green), 'yellow': len(yellow),
            'red': len(red), 'gray': len(gray)
        }
    return JSONResponse({"code": CODE_SUCCESS, "status": {user_id: res}})


@router.post("/local_doc_qa/clean_files_by_status")
async def clean_files_by_status(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info('clean_files_by_status %s', user_id)
    status = body.get('status', 'gray')
    kb_ids = body.get('kb_ids')
    if not kb_ids:
        kbs = local_doc_qa.kb_manager.get_knowledge_bases(user_id)
        kb_ids = [kb[0] for kb in kbs]
    else:
        not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, kb_ids)
        if not_exist_kb_ids:
            return JSONResponse({"code": CODE_KB_MISSING, "msg": f"fail, knowledge Base {not_exist_kb_ids} not found"})
    gray_file_infos = local_doc_qa.kb_manager.get_file_by_status(kb_ids, status)
    gray_file_ids = [f[0] for f in gray_file_infos]
    gray_file_names = [f[1] for f in gray_file_infos]
    debug_logger.info('%s files number: %d', status, len(gray_file_names))
    if gray_file_ids:
        faiss_kb = local_doc_qa.match_milvus_kb(user_id, kb_ids)
        faiss_kb.delete_files(gray_file_ids)
        # SQL WHERE kb_id=? safely filters per kb; no cross-kb deletion risk
        for kb_id in kb_ids:
            local_doc_qa.kb_manager.delete_files(kb_id, gray_file_ids)
    return JSONResponse({"code": CODE_SUCCESS, "msg": f"delete {status} files success", "data": gray_file_names})


@router.post("/local_doc_qa/local_doc_chat")
async def local_doc_chat(request: Request):
    local_doc_qa = _get_local_doc_qa(request)
    user_id, body = await _parse_user_request(request)
    debug_logger.info('local_doc_chat %s', user_id)
    kb_ids = body.get('kb_ids')
    question = body.get('question')
    if not kb_ids:
        raise _UserIdError({"code": CODE_INVALID_INPUT, "msg": "kb_ids 不能为空"})
    if not question:
        return JSONResponse({"code": CODE_INVALID_INPUT, "msg": "question 不能为空"})
    rerank = body.get('rerank', True)
    debug_logger.info('rerank %s', rerank)
    streaming = body.get('streaming', False)
    history = body.get('history', [])
    debug_logger.info("history: %s", history)
    debug_logger.info("question: %s", question)
    debug_logger.info("kb_ids: %s", kb_ids)
    debug_logger.info("user_id: %s", user_id)

    not_exist_kb_ids = local_doc_qa.kb_manager.check_kb_exist(user_id, kb_ids)
    if not_exist_kb_ids:
        return JSONResponse({"code": CODE_KB_MISSING, "msg": f"fail, knowledge Base {not_exist_kb_ids} not found"})

    file_infos = []
    faiss_kb = local_doc_qa.match_milvus_kb(user_id, kb_ids)
    for kb_id in kb_ids:
        file_infos.extend(local_doc_qa.kb_manager.get_files(user_id, kb_id))
    valid_files = [fi for fi in file_infos if fi[2] == 'green']

    debug_logger.info("len(valid_files): %d", len(valid_files))

    if streaming:
        debug_logger.info("start generate answer (streaming)")

        async def generate_answer():
            try:
                gen = local_doc_qa.get_knowledge_based_answer(
                    query=question, milvus_kb=faiss_kb, chat_history=history,
                    streaming=True, rerank=rerank
                )
                loop = asyncio.get_running_loop()
                while True:
                    result = await loop.run_in_executor(_executor, next, gen, _GEN_SENTINEL)
                    if result is _GEN_SENTINEL:
                        break
                    resp, next_history = result
                    chunk_data = resp["result"]
                    if not chunk_data:
                        continue
                    chunk_str = chunk_data[SSE_DATA_PREFIX_LEN:]
                    if chunk_str.startswith("[DONE]"):
                        retrieval_docs = format_source_documents(resp["retrieval_documents"])
                        source_docs = format_source_documents(resp["source_documents"])
                        chat_data = {
                            'user_info': user_id, 'kb_ids': kb_ids, 'query': question,
                            'history': history, 'prompt': resp['prompt'],
                            'result': next_history[-1][1],
                            'retrieval_documents': retrieval_docs,
                            'source_documents': source_docs,
                        }
                        qa_logger.info("chat_data: %s", chat_data)
                        debug_logger.info("response: %s", chat_data['result'])
                        stream_res = {
                            "code": CODE_SUCCESS, "msg": "success",
                            "question": question, "response": "",
                            "history": next_history,
                            "source_documents": source_docs,
                        }
                    else:
                        try:
                            chunk_js = json.loads(chunk_str)
                        except json.JSONDecodeError:
                            continue
                        delta_answer = chunk_js.get("answer", "")
                        stream_res = {
                            "code": CODE_SUCCESS, "msg": "success",
                            "question": "", "response": delta_answer,
                            "history": [], "source_documents": [],
                        }
                    yield f"data: {json.dumps(stream_res, ensure_ascii=False)}\n\n"
                    if chunk_str.startswith("[DONE]"):
                        yield "data: [DONE]\n\n"
                        break
                    await asyncio.sleep(0.001)
            except Exception:
                logging.error("Streaming chat error: %s", traceback.format_exc())
                debug_logger.error("Streaming chat error: %s", traceback.format_exc())
                error_res = {
                    "code": CODE_LLM_ERROR, "msg": "LLM streaming error",
                    "question": question, "response": "",
                    "history": history, "source_documents": [],
                }
                yield f"data: {json.dumps(error_res, ensure_ascii=False)}\n\n"
                yield "data: [DONE]\n\n"

        return StreamingResponse(generate_answer(), media_type="text/event-stream")
    else:
        loop = asyncio.get_running_loop()
        gen = local_doc_qa.get_knowledge_based_answer(
            query=question, milvus_kb=faiss_kb, chat_history=history,
            streaming=False, rerank=rerank
        )
        resp = None
        try:
            while True:
                result = await loop.run_in_executor(_executor, next, gen, _GEN_SENTINEL)
                if result is _GEN_SENTINEL:
                    break
                resp, history = result
        except Exception:
            logging.error("Non-streaming chat error: %s", traceback.format_exc())
            debug_logger.error("Non-streaming chat error: %s", traceback.format_exc())
            return JSONResponse({
                "code": CODE_LLM_ERROR, "msg": "LLM error",
                "question": question, "response": "",
                "history": history, "source_documents": [],
            })
        if resp is None:
            return JSONResponse({
                "code": CODE_LLM_ERROR, "msg": "LLM returned no response",
                "question": question, "response": "",
                "history": history, "source_documents": [],
            })
        retrieval_documents = format_source_documents(resp["retrieval_documents"])
        source_documents = format_source_documents(resp["source_documents"])
        # Use accumulated answer from history (resp["result"] is raw LLM output)
        accumulated_answer = history[-1][1] if history and history[-1] else ""
        chat_data = {
            'user_id': user_id, 'kb_ids': kb_ids, 'query': question,
            'history': history, 'retrieval_documents': retrieval_documents,
            'prompt': resp['prompt'], 'result': accumulated_answer,
            'source_documents': source_documents,
        }
        qa_logger.info("chat_data: %s", chat_data)
        debug_logger.info("response: %s", chat_data['result'])
        return JSONResponse({
            "code": CODE_SUCCESS, "msg": "success chat",
            "question": question, "response": accumulated_answer,
            "history": history, "source_documents": source_documents,
        })
