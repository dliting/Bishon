# Bishon V2 API 接口文档

## 全局参数

每个接口通过 `user_id` 区分用户。`user_id` 需满足：以字母开头，只允许包含字母、数字或下划线。

前端页面固定使用 `user_id="default_user"`，因此 API 传入 `user_id="default_user"` 时，通过 API 上传的数据可以在前端页面中看到；传入其他值则前端页面不可见。以下示例使用 `user1` 作为演示用户。

## 错误码

| 错误码 | 含义 |
|--------|------|
| 200 | 成功 |
| 2001 | kb_id 不存在 |
| 2002 | 参数缺失或非法 |
| 2003 | 知识库未找到 |
| 2004 | file_ids 为空或文件未找到 |
| 2005 | user_id 格式非法 |
| 500 | LLM 内部错误 |

---

## 新建知识库

`POST /api/local_doc_qa/new_knowledge_base`

### 请求参数（JSON Body）

| 参数名  | 示例值   | 必填 | 类型   | 说明       |
| ------- | -------- | ---- | ------ | ---------- |
| user_id | "user1"  | 是   | String | 用户 id |
| kb_name | "kb_test" | 是   | String | 知识库名称 |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/new_knowledge_base \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_name": "kb_test"}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "success create knowledge base KBd728811ed16b46f9a2946e28dd5c9939",
  "data": {
    "kb_id": "KB4c50de98d6b548af9aa0bc5e10b2e3a7",
    "kb_name": "kb_test",
    "timestamp": "202605171057"
  }
}
```

---

## 上传文件

`POST /api/local_doc_qa/upload_files`

Content-Type: `multipart/form-data`

### 请求参数（Form Data）

| 参数名  | 必填 | 类型   | 说明                                                                                                    |
| ------- | ---- | ------ | ------------------------------------------------------------------------------------------------------- |
| files   | 是   | File   | 上传的文件，可多选。支持：md, txt, pdf, jpg, png, jpeg, docx, xlsx, pptx, eml, csv（图片和 PDF 需 PaddleOCR） |
| user_id | "user1" | 是   | String | 用户 id |
| kb_id   | 是   | String | 知识库 id                                                                                               |
| mode    | 否   | String | 上传模式：`soft`（同名文件跳过）或 `strong`（同名强制上传），默认 `soft`                               |

### curl 示例

```bash
# 上传单个文件
curl -X POST http://localhost:8777/api/local_doc_qa/upload_files \
  -F "user_id=user1" \
  -F "kb_id=KB6dae785cdd5d47a997e890521acbe1c9" \
  -F "mode=soft" \
  -F "files=@./doc.txt"

# 上传多个文件
curl -X POST http://localhost:8777/api/local_doc_qa/upload_files \
  -F "user_id=user1" \
  -F "kb_id=KB6dae785cdd5d47a997e890521acbe1c9" \
  -F "mode=strong" \
  -F "files=@./a.txt" \
  -F "files=@./b.docx"
```

### 响应示例

```json
{
  "code": 200,
  "msg": "success，后台正在飞速上传文件，请耐心等待",
  "data": [
    {
      "file_id": "1b6c0781fb9245b2973504cb031cc2f3",
      "file_name": "test.txt",
      "status": "gray",
      "bytes": 17925,
      "timestamp": "202605171056"
    }
  ]
}
```

**文件状态说明**：

| 状态    | 含义                   |
| ------- | ---------------------- |
| gray    | 正在入库               |
| green   | 成功入库               |
| red     | 入库失败（切分失败）   |
| yellow  | 入库失败（FAISS 失败） |

---

## 上传网页链接

`POST /api/local_doc_qa/upload_weblink`

### 请求参数（JSON Body）

| 参数名  | 示例值                                                    | 必填 | 类型   | 说明       |
| ------- | --------------------------------------------------------- | ---- | ------ | ---------- |
| url     | "https://example.com/page.html"                           | 是   | String | 网页 URL   |
| user_id | "user1"                                                   | 是   | String | 用户 id    |
| kb_id   | "KBb1dd58e8485443ce81166d24f6febda7"                      | 是   | String | 知识库 id  |
| mode    | "soft"                                                    | 否   | String | 上传模式，默认 `soft` |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/upload_weblink \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_id": "KBb1dd58e8485443ce81166d24f6febda7", "url": "https://example.com/page.html"}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "success，后台正在飞速上传文件，请耐心等待",
  "data": [
    {
      "file_id": "9a49392e633d4c6f87e0af51e8c80a86",
      "file_name": "https://example.com/page.html",
      "status": "gray",
      "bytes": 0,
      "timestamp": "202605261809"
    }
  ]
}
```

---

## 查看知识库列表

`POST /api/local_doc_qa/list_knowledge_base`

### 请求参数（JSON Body）

| 参数名  | 示例值  | 必填 | 类型   | 说明    |
| ------- | ------- | ---- | ------ | ------- |
| user_id | "user1" | 是   | String | 用户 id |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/list_knowledge_base \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1"}'
```

### 响应示例

```json
{
  "code": 200,
  "data": [
    {
      "kb_id": "KB973d4aea07f14c60ae1974404a636ad4",
      "kb_name": "dataset_s_1"
    }
  ]
}
```

---

## 获取文件列表

`POST /api/local_doc_qa/list_files`

### 请求参数（JSON Body）

| 参数名  | 示例值                                | 必填 | 类型   | 说明      |
| ------- | ------------------------------------- | ---- | ------ | --------- |
| user_id | "user1"                               | 是   | String | 用户 id   |
| kb_id   | "KBb1dd58e8485443ce81166d24f6febda7"  | 是   | String | 知识库 id |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/list_files \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_id": "KBb1dd58e8485443ce81166d24f6febda7"}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "success",
  "data": {
    "total": {
      "green": 100,
      "red": 1,
      "gray": 1,
      "yellow": 1
    },
    "details": [
      {
        "file_id": "21a9f13832594b0f936b62a54254543b",
        "file_name": "产品介绍.pptx",
        "status": "green",
        "bytes": 177925,
        "content_length": 3059,
        "timestamp": "202605261708",
        "msg": "上传成功"
      }
    ]
  }
}
```

---

## 问答接口

`POST /api/local_doc_qa/local_doc_chat`

### 请求参数（JSON Body）

| 参数名    | 示例值                                                    | 必填 | 类型         | 说明                             |
| --------- | --------------------------------------------------------- | ---- | ------------ | -------------------------------- |
| user_id   | "user1"                                                   | 是   | String       | 用户 id                          |
| kb_ids    | ["KBb1dd58e8485443ce81166d24f6febda7", "KB633c69d0..."]  | 是   | Array        | 知识库 id 列表，支持多库联合问答 |
| question  | "保险单号是多少？"                                        | 是   | String       | 问题                             |
| history   | [["q1","a1"],["q2","a2"]]                                 | 否   | Array[Array] | 历史对话                         |
| rerank    | true                                                      | 否   | Bool         | 是否开启 rerank，默认 true       |
| streaming | false                                                     | 否   | Bool         | 是否开启流式输出，默认 false     |

### curl 示例

```bash
# 非流式问答
curl -X POST http://localhost:8777/api/local_doc_qa/local_doc_chat \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_ids": ["KBf652e9e379c546f1894597dcabdc8e47"], "question": "保险单号是多少？", "streaming": false}'

# 流式问答（SSE）
curl -X POST http://localhost:8777/api/local_doc_qa/local_doc_chat \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_ids": ["KBf652e9e379c546f1894597dcabdc8e47"], "question": "你好", "streaming": true}'
```

### 非流式响应示例

```json
{
  "code": 200,
  "msg": "success chat",
  "question": "保险单号是多少？",
  "response": "保险单号是601J312512022000536。",
  "history": [["保险单号是多少？", "保险单号是601J312512022000536。"]],
  "source_documents": [
    {
      "file_id": "f9b794233c304dd5b5a010f2ead67f51",
      "file_name": "授权书.docx",
      "content": "...",
      "retrieval_query": "保险单号是多少？",
      "score": "3.5585756",
      "embed_version": "local_v0.0.1"
    }
  ]
}
```

### 流式响应示例（SSE）

每行格式为 `data: {json}\n\n`，最后以 `data: [DONE]\n\n` 结束：

```
data: {"code": 200, "msg": "success", "question": "", "response": "你", "history": [], "source_documents": []}

data: {"code": 200, "msg": "success", "question": "", "response": "好", "history": [], "source_documents": []}

data: {"code": 200, "msg": "success", "question": "你好", "response": "你好！有什么问题我可以帮助你解答吗？", "history": [["你好", "你好！有什么问题我可以帮助你解答吗？"]], "source_documents": []}

data: [DONE]
```

---

## 删除文件

`POST /api/local_doc_qa/delete_files`

### 请求参数（JSON Body）

| 参数名   | 示例值                                | 必填 | 类型  | 说明                       |
| -------- | ------------------------------------- | ---- | ----- | -------------------------- |
| user_id  | "user1"                               | 是   | String | 用户 id                    |
| kb_id    | "KB1271e71c36ec4028a6542586946a3906"  | 是   | String | 知识库 id                  |
| file_ids | ["73ff7cf76ff34c8aa3a5a0b4ba3cf534"]  | 是   | Array | 要删除的文件 id，支持批量 |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/delete_files \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_id": "KB1271e71c36ec4028a6542586946a3906", "file_ids": ["73ff7cf76ff34c8aa3a5a0b4ba3cf534"]}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "documents ['73ff7cf76ff34c8aa3a5a0b4ba3cf534'] delete success"
}
```

---

## 删除知识库

`POST /api/local_doc_qa/delete_knowledge_base`

### 请求参数（JSON Body）

| 参数名  | 示例值                                | 必填 | 类型  | 说明                         |
| ------- | ------------------------------------- | ---- | ----- | ---------------------------- |
| user_id | "user1"                               | 是   | String | 用户 id                      |
| kb_ids  | ["KB1cd81f2bc515437294bda1934a20b235"] | 是   | Array | 要删除的知识库 id，支持批量 |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/delete_knowledge_base \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_ids": ["KB1cd81f2bc515437294bda1934a20b235"]}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "Knowledge Base ['KB1cd81f2bc515437294bda1934a20b235'] delete success"
}
```

---

## 重命名知识库

`POST /api/local_doc_qa/rename_knowledge_base`

### 请求参数（JSON Body）

| 参数名      | 示例值                          | 必填 | 类型   | 说明               |
| ----------- | ------------------------------- | ---- | ------ | ------------------ |
| user_id     | "user1"                         | 是   | String | 用户 id            |
| kb_id       | "KB0015df77a8eb46f6951de51..."  | 是   | String | 知识库 id          |
| new_kb_name | "新知识库"                      | 是   | String | 新的知识库名称     |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/rename_knowledge_base \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_id": "KB0015df77a8eb46f6951de513392dc250", "new_kb_name": "新知识库"}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "Knowledge Base KB0015df77a8eb46f6951de513392dc250 rename success"
}
```

---

## 下载原始文件（文档溯源）

`GET /api/local_doc_qa/download_file/{file_id}`

通过 `file_id` 下载原始上传文件。浏览器根据 Content-Type 自动决定预览或下载。
URL 类型的来源文档（通过 upload_weblink 上传）返回 302 重定向到原始 URL。

### 路径参数

| 参数名  | 示例值                              | 必填 | 类型   | 说明                        |
| ------- | ----------------------------------- | ---- | ------ | --------------------------- |
| file_id | "a1b2c3d4e5f6..."                  | 是   | String | 文件 ID（来自 source_documents） |

### curl 示例

```bash
# 下载文件（浏览器支持的格式会自动预览）
curl -O http://localhost:8777/api/local_doc_qa/download_file/a1b2c3d4e5f6...

# URL 类型文件会返回 302 重定向
curl -v http://localhost:8777/api/local_doc_qa/download_file/abcdef1234567890...
```

### 响应

- **文件类型**: 返回文件内容（Content-Type 根据文件扩展名自动设置）
- **URL 类型**: 返回 302 重定向到原始 URL

### 错误响应

| HTTP 状态码 | 错误码 | 说明                   |
| ----------- | ------ | ---------------------- |
| 404         | 2004   | file_id 不存在         |
| 404         | 2004   | 文件已删除             |
| 404         | 2004   | 磁盘文件丢失           |

---

## 获取所有知识库状态

`POST /api/local_doc_qa/get_total_status`

### 请求参数（JSON Body）

| 参数名  | 示例值  | 必填 | 类型   | 说明    |
| ------- | ------- | ---- | ------ | ------- |
| user_id | "user1" | 是   | String | 用户 id |

### curl 示例

```bash
curl -X POST http://localhost:8777/api/local_doc_qa/get_total_status \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1"}'
```

### 响应示例

```json
{
  "code": 200,
  "status": {
    "user1": {
      "默认知识库KB0015df77a8eb46f6951de513392dc250": {
        "green": 10,
        "yellow": 0,
        "red": 0,
        "gray": 0
      }
    }
  }
}
```

---

## 清理指定状态的文件

`POST /api/local_doc_qa/clean_files_by_status`

### 请求参数（JSON Body）

| 参数名  | 示例值                                 | 必填 | 类型   | 说明                                                         |
| ------- | -------------------------------------- | ---- | ------ | ------------------------------------------------------------ |
| user_id | "user1"                                | 是   | String | 用户 id                                                      |
| status  | "gray"                                 | 否   | String | 要清理的文件状态，默认 `gray`                                |
| kb_ids  | ["KB0015df77...", "KB6a4534f7..."]     | 否   | Array  | 知识库 id 列表。不传则清理该用户所有知识库                   |

### curl 示例

```bash
# 清理指定知识库中的 gray 文件
curl -X POST http://localhost:8777/api/local_doc_qa/clean_files_by_status \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "kb_ids": ["KB0015df77a8eb46f6951de513392dc250"], "status": "gray"}'

# 清理用户所有知识库中的 gray 文件
curl -X POST http://localhost:8777/api/local_doc_qa/clean_files_by_status \
  -H "Content-Type: application/json" \
  -d '{"user_id": "user1", "status": "gray"}'
```

### 响应示例

```json
{
  "code": 200,
  "msg": "delete gray files success",
  "data": [
    "测试文件.txt",
    "产品介绍.pptx"
  ]
}
```

---

## 健康检查

`GET /api/health`

返回系统健康状态，包括各服务可用性和请求队列信息。无需 `user_id`。

### curl 示例

```bash
curl http://localhost:8777/api/health
```

### 响应示例

```json
{
  "status": "ok",
  "version": "2.1.0",
  "uptime_seconds": 3600.5,
  "services": {
    "llm": {
      "status": "healthy",
      "detail": "ollama qwen3:8b @ http://localhost:11434/v1",
      "last_check": 1722500000.0,
      "last_success": 1722500000.0,
      "latency_ms": 45.2
    },
    "embedding": {
      "status": "healthy",
      "detail": "qwen3-embedding:0.6b @ http://localhost:11434/v1",
      "last_check": 1722500000.0,
      "last_success": 1722500000.0,
      "latency_ms": 32.1
    },
    "rerank": {
      "status": "disabled",
      "detail": "disabled (RERANK_ENABLED=false)",
      "last_check": 1722500000.0,
      "last_success": null,
      "latency_ms": 0.0
    },
    "ocr": {
      "status": "healthy",
      "detail": "PaddleOCR GPU",
      "last_check": 1722500000.0,
      "last_success": 1722500000.0,
      "latency_ms": 0.0
    },
    "faiss": {
      "status": "healthy",
      "detail": "1024-dim, 3 collection(s)",
      "last_check": 1722500000.0,
      "last_success": 1722500000.0,
      "latency_ms": 0.0
    },
    "sqlite": {
      "status": "healthy",
      "detail": "/opt/Bishon/V2/dev/BISHON_DB/bishon.db",
      "last_check": 1722500000.0,
      "last_success": 1722500000.0,
      "latency_ms": 0.3
    }
  },
  "queue": {
    "pending_tasks": 2,
    "active_tasks": 3,
    "max_workers": 4
  }
}
```

### 字段说明

| 字段 | 说明 |
|------|------|
| `status` | 整体状态：`ok`（所有非禁用服务正常）或 `degraded`（有服务异常） |
| `version` | 应用版本号 |
| `uptime_seconds` | 服务运行时长（秒） |
| `services.*.status` | 服务状态：`healthy` / `unhealthy` / `unknown` / `disabled` |
| `services.*.detail` | 服务详情描述 |
| `services.*.latency_ms` | 最近检测延迟（毫秒），0 表示纯状态检查 |
| `queue.pending_tasks` | 等待执行的请求数 |
| `queue.active_tasks` | 正在执行的请求数 |
| `queue.max_workers` | 最大并发工作线程数 |

---

## API 文档入口

`GET /api/docs`

返回纯文本格式的 API 接口列表。

### curl 示例

```bash
curl http://localhost:8777/api/docs
```
