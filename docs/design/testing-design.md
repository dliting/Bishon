# Bishon V2 全面测试体系设计

## 概述

为 Bishon V2（本地知识库问答系统）建立分层测试金字塔：单元测试 → API 集成测试 → 前端组件测试 → E2E 交互测试 → 脚本测试。覆盖后端 Python（FastAPI + SQLite + FAISS）和前端 Vue 3（Vite + Pinia + Ant Design Vue）。

**测试原则：**
- 真实服务优先：SQLite/FAISS 用真实实例，LLM/Embedding/OCR 在 mock 测试中 mock 掉，提供可选真实服务测试
- 每层独立可运行，互不依赖
- 启动/停止脚本也有专门的 shell 测试
- E2E 测试步骤形成独立文档，便于手工复用和回归

---

## 1. 目录结构

```
tests/
  backend/
    conftest.py                          # 全局 fixtures
    unit/
      test_general_utils.py              # 工具函数
      test_sqlite_client.py              # SQLite CRUD
      test_faiss_client.py               # FAISS 向量索引
      test_local_doc_qa.py               # 核心问答逻辑（去重、prompt、rerank）
      test_local_file.py                 # 文件解析与分割
      test_llm_client.py                 # LLM 客户端（mock OpenAI API）
      test_embedding_client.py           # Embedding 客户端（mock）
      test_rerank_client.py              # Rerank 客户端（mock transformers）
    integration/
      conftest.py                        # FastAPI TestClient fixture
      test_api_knowledge_base.py         # 知识库 CRUD API
      test_api_file_upload.py            # 文件上传/删除 API
      test_api_chat.py                   # 问答 API（流式 SSE + 非流式）
      test_api_edge_cases.py             # 边界场景
  frontend/
    vitest.config.ts
    unit/
      stores/
        test_useKnowledgeBase.ts         # 知识库 store
        test_useChat.ts                  # 聊天 store
        test_useUser.ts                  # 用户 store
        test_useKnowledgeModal.ts        # 上传弹窗 store
        test_useOptionList.ts            # 文件管理 store（含轮询）
      utils/
        test_utils.ts                    # getStatus / formatFileSize / formatDate / throttle
        test_typewriter.ts               # 打字机队列
        test_resConfig.ts                # 响应码判断
    e2e/
      playwright.config.ts
      fixtures/
        test.txt                         # 测试用文件
        test.pdf                         # 测试用 PDF
        test.csv                         # 测试用 CSV
      specs/
        knowledge-base.spec.ts           # 知识库管理
        file-upload.spec.ts              # 文件上传
        chat.spec.ts                     # 问答交互（SSE 流式）
        startup.spec.ts                  # 启动→使用→停止 全生命周期
  scripts/
    test_start_sh.sh                     # start.sh 脚本测试
    test_start_bat.bat                   # start.bat 脚本测试（Windows）

docs/
  design/
    testing-design.md                    # this document
    ui-test-steps.md                     # reusable UI test-step playbook
```

---

## 2. 后端单元测试（pytest）

### 2.1 test_general_utils.py

测试 `bishon_kernel/utils/general_utils.py` 中的纯函数：

| 函数 | 测试用例 |
|------|---------|
| `validate_user_id` | 合法（`abc123`、`A_b`、`Z_0`）；非法（`123abc` 数字开头、`a-b` 含横线、空串、None、含空格、纯数字、超长字符串） |
| `truncate_filename` | 短文件名不变（`a.txt`）、长文件名截断保留扩展名（200 字节阈值）、中文文件名（`测试文档.pdf`）、无扩展名、纯扩展名（`.gitignore`） |
| `format_source_documents` | 空 list 返回 `[]`、单条 Document（含全部 metadata）、缺失 metadata 字段不崩溃（用 `.get()` 默认值）、多条排序 |
| `isURL` | 合法（`http://a.com`、`https://b.com/path`）；非法（`not_a_url`、空串、`/relative/path`） |
| `num_tokens` | tiktoken 可用时精确计数、`HAS_TIKTOKEN=False` 时近似 `len//4` |
| `get_time` | 装饰器后函数仍返回原值、打印耗时到 stdout |

### 2.2 test_sqlite_client.py

测试 `KnowledgeBaseManager`（`bishon_kernel/connector/database/sqlite/sqlite_client.py`），每个测试用独立临时 DB：

| 方法 | 测试用例 |
|------|---------|
| `create_tables_` | 首次创建三张表 + FTS5、重复调用不报错 |
| `add_user_` / `check_user_exist_` | 新增成功、`INSERT OR IGNORE` 重复不报错、查询存在/不存在 |
| `get_users` | 多用户列表 |
| `new_milvus_base` | 创建知识库并自动创建用户、返回 `(kb_id, "success")` |
| `check_kb_exist` | 全部存在返回 `[]`、部分不存在返回差集、空列表返回 `[]`、已软删除的视为不存在 |
| `get_knowledge_bases` | 有数据返回列表、无数据返回空、软删除的不出现 |
| `get_knowledge_base_name` | 按 kb_ids 批量查询 |
| `delete_knowledge_base` | 软删除（`deleted=1`）、关联文件也标记删除、重复删除无异常 |
| `rename_knowledge_base` | 正常重命名后查询验证、重命名不存在的无异常 |
| `add_file` | 正常添加返回 `(file_id, "success")`、无效 user_id 返回 `(None, msg)`、无效 kb_id 返回 `(None, msg)` |
| `update_file_size` / `update_content_length` / `update_chunk_size` | 更新后查询验证 |
| `get_files` | 按用户+kb 过滤、不返回已删除的、返回字段完整（6 列） |
| `delete_files` | 批量软删除、空列表不报错 |
| `check_file_exist` | 按 ID 查找、跨用户隔离（用户 A 看不到用户 B 的文件） |
| `check_file_exist_by_name` | 按名查找、批量>100 条时分批查询、跨用户隔离 |
| `update_file_status` | gray→green、gray→red、yellow→green |
| `get_file_by_status` | 按 status 筛选、多 kb_ids 批量查询 |
| `from_status_to_status` | 条件更新（仅 from_status 匹配的行才更新） |
| FTS5 操作 | `insert_fts_chunks` + `search_fts` 往返、`delete_fts_chunks`、FTS5 不可用时 graceful fallback |

**Fixture：**
```python
@pytest.fixture
def tmp_db(tmp_path, monkeypatch):
    db_path = str(tmp_path / "test.db")
    monkeypatch.setattr("bishon_kernel.connector.database.sqlite.sqlite_client.DB_PATH", db_path)
    monkeypatch.setattr("bishon_kernel.connector.database.sqlite.sqlite_client.DB_DIR", str(tmp_path))
    return KnowledgeBaseManager()
```

### 2.3 test_faiss_client.py

测试 `FaissClient`（`bishon_kernel/connector/database/faiss/faiss_client.py`），CPU-only 模式：

| 方法 | 测试用例 |
|------|---------|
| `_create_new` | CPU fallback 创建成功、索引维度 768、`ntotal=0` |
| `_load_or_create` | 首次创建、已有文件时加载、损坏文件时 fallback 重建 |
| `insert_files` | 插入单文件多 chunk（验证 ntotal 增加）、元数据 `_chunk_meta` 正确、返回 True |
| `search_emb_async` | 插入后搜索能找到（score 排序正确）、空索引返回 `[[]]`、阈值过滤、top_k 限制 |
| `delete_files` | 删除后搜索不到、删除全部后 ntotal=0 且 meta 为空、字符串输入自动转 list |
| `delete_partition` | 按 kb_id 删除指定分区的所有 chunk |
| `get_files` | 返回存在的 file_id 列表 |
| `seperate_list` | 连续 ID `[1,2,3,5,6]` → `[[1,2,3],[5,6]]`、单元素 |
| `expand_cand_docs` | 非 CSV/XLSX 文件触发上下文扩展、CSV/XLSX 不扩展、空输入 |
| `_save` / `_load_or_create` | 持久化后重载，索引和元数据一致 |

**Fixture：**
```python
@pytest.fixture
def tmp_faiss(tmp_path, monkeypatch):
    monkeypatch.setattr("bishon_kernel.connector.database.faiss.faiss_client.FAISS_DIR", str(tmp_path))
    db_path = str(tmp_path / "meta.db")
    monkeypatch.setattr("bishon_kernel.connector.database.sqlite.sqlite_client.DB_PATH", db_path)
    monkeypatch.setattr("bishon_kernel.connector.database.sqlite.sqlite_client.DB_DIR", str(tmp_path))
    kb_mgr = KnowledgeBaseManager()
    return FaissClient("test_user", ["KB_test"], threshold=1.1, kb_manager=kb_mgr)
```

### 2.4 test_local_doc_qa.py

测试 `LocalDocQA`（`bishon_kernel/core/local_doc_qa.py`）的非初始化方法：

| 方法 | 测试用例 |
|------|---------|
| `deduplicate_documents` | 重复内容去重、空列表、全部唯一、全部相同 |
| `generate_prompt` | 模板中 `{question}` 和 `{context}` 被正确替换 |
| `rerank_documents` | rerank 关闭时直接返回、mock `predict` 返回分数后排序正确、query 超 300 字符跳过 rerank |
| `_calc_mean_score` | 正常计算均值、空列表返回 0 |
| `reprocess_source_documents` | token 限制裁剪逻辑（mock LLM token 计数） |
| `get_source_documents` | mock embedding + mock faiss 搜索，验证返回结构 |

### 2.5 test_local_file.py

测试 `LocalFile`（`bishon_kernel/core/local_file.py`），mock embedding：

| 测试场景 | 说明 |
|---------|------|
| TXT 文件分割 | 创建临时 .txt，验证 docs 非空、metadata 含 file_id 和 file_name |
| MD 文件解析 | 临时 .md 文件 |
| CSV 文件解析 | 临时 .csv 文件，验证按行分割 |
| 不支持的文件类型 | 如 `.rar`，验证抛出 TypeError |
| `create_embedding` | mock `_get_len_safe_embeddings` 返回 768 维向量，验证数量匹配 docs 数 |
| URL 模式 | `is_url=True` 时 `file_path="URL"`，验证 URL loader 调用 |

**注意：** 需要在 fixture 中 mock `model_config.UPLOAD_ROOT_PATH` 到 tmp_path，避免写入真实目录。

### 2.6 test_llm_client.py

测试 `OpenAILLM`（`bishon_kernel/connector/llm/llm_for_openai_api.py`），mock OpenAI SDK：

| 测试场景 | 说明 |
|---------|------|
| 非流式 `_call` | mock `client.chat.completions.create(stream=False)`，验证 yield 格式 `"data: {...}"` + `"data: [DONE]"` |
| 流式 `_call` | mock 流式 `create(stream=True)`，验证多个 chunk 逐个 yield |
| `num_tokens_from_messages` | 字符串消息、dict 消息 `{"role":"user","content":"..."}`、混合类型 |
| `num_tokens_from_docs` | Document 列表的 token 计数 |
| `generatorAnswer` | mock `_call`，验证 `AnswerResult` 结构（history、llm_output、prompt） |
| API 异常 | mock raise Exception，验证 yield 错误消息而非崩溃 |

### 2.7 test_embedding_client.py

测试 `OpenAIEmbeddings`（`bishon_kernel/connector/embedding/openai_embedding.py`）：

| 测试场景 | 说明 |
|---------|------|
| `_get_embedding` | mock `client.embeddings.create`，验证返回 List[List[float]] |
| `_get_len_safe_embeddings` | 20 个文本 batch_size=16，验证分 2 批调用、结果拼接正确 |
| `embed_version` 属性 | 返回 `"openai_compatible_v1"` |
| `__hash__` | 基于模型名 hash |

### 2.8 test_rerank_client.py

测试 `LocalRerankBackend`（`bishon_kernel/connector/rerank/rerank_client.py`）：

| 测试场景 | 说明 |
|---------|------|
| 默认关闭 | `RERANK_ENABLED=False` 时 `enabled=False`，`predict` 返回 `[0.5]*n` |
| 模型路径不存在 | `self.enabled=False` |
| generative 模式 | mock `transformers.AutoModelForCausalLM`，验证 `_predict_generative` 的 yes/no token scoring |
| cross_encoder 模式 | mock `transformers.AutoModelForSequenceClassification`，验证 sigmoid 输出 |
| 空 passages | `predict("query", [])` 返回 `[]` |

---

## 3. 后端 API 集成测试（pytest + httpx）

### 3.1 conftest.py

```python
@pytest.fixture
async def api_client(tmp_path, monkeypatch):
    """FastAPI TestClient，临时 SQLite/FAISS，mock LLM/Embedding/OCR"""
    # 1. monkeypatch DB_PATH, FAISS_DIR 到 tmp_path
    # 2. mock LocalDocQA.init_cfg：手动创建 SQLite KB manager + 空 FAISS
    # 3. mock OpenAILLM / OpenAIEmbeddings / PaddleOCR
    # 4. 触发 FastAPI lifespan 手动初始化 app.state.local_doc_qa
    # 5. 返回 httpx.AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
```

### 3.2 test_api_knowledge_base.py

| 端点 | 测试用例 |
|------|---------|
| `POST /api/local_doc_qa/new_knowledge_base` | 正常创建返回 `code:200` + `kb_id` + `kb_name` + `timestamp`；缺少 `user_id` 返回 `code:2002`；非法 `user_id`（数字开头）返回 `code:2005` |
| `POST /api/local_doc_qa/list_knowledge_base` | 有知识库返回 `data` 数组；无知识库返回 `data:[]`；非法 user_id 返回 2005 |
| `POST /api/local_doc_qa/delete_knowledge_base` | 正常删除返回 200；删除不存在的返回 2003；删除后 list 不再包含 |
| `POST /api/local_doc_qa/rename_knowledge_base` | 正常重命名后 list 中名称更新；重命名不存在返回 2003 |

### 3.3 test_api_file_upload.py

| 端点 | 测试用例 |
|------|---------|
| `POST /api/local_doc_qa/upload_files` | 上传单个 TXT 文件返回 `data[0].file_id`；多文件上传返回多条；`mode=soft` 同名文件返回 warning；`mode=strong` 允许覆盖；无效 `kb_id` 返回 2001 |
| `POST /api/local_doc_qa/upload_weblink` | 正常上传 URL 返回 `file_id`；空 URL 返回 2002；无效 kb_id 返回 2001；soft 模式同名 URL 拒绝 |
| `POST /api/local_doc_qa/list_files` | 上传后查看文件列表包含 `total`（各状态计数）和 `details` |
| `POST /api/local_doc_qa/delete_files` | 删除后 list_files 不再包含；空 `file_ids` 返回 2004 |
| `POST /api/local_doc_qa/get_total_status` | 返回各状态文件计数 |
| `POST /api/local_doc_qa/clean_files_by_status` | 清理 gray 文件成功；不传 kb_ids 时清理全部知识库 |

### 3.4 test_api_chat.py

**重要：** 前端使用 SSE（`@microsoft/fetch-event-source`）连接 `/local_doc_qa/local_doc_chat`，后端根据 `streaming` 参数返回 SSE 或 JSON。

| 端点 | 测试用例 |
|------|---------|
| 非流式 `streaming=False` | 空 kb（无 green 文件）返回提示消息；mock LLM 返回答案，验证 `response`/`history`/`source_documents` 结构 |
| 流式 `streaming=True` | 返回 `text/event-stream`；SSE 格式 `data: {...}\n\n`；最后一条含 `source_documents`；以 `data: [DONE]\n\n` 结尾 |
| 空 kb 流式 | 返回单条 SSE 消息 + `[DONE]` |
| 缺少 `question` | 返回 `code:2002` |
| 无效 `kb_ids` | 返回 `code:2003` |

### 3.5 test_api_edge_cases.py

| 测试场景 | 说明 |
|---------|------|
| 空 JSON 体 `{}` | 各端点返回对应错误码（2002 或 2005） |
| 超长 user_id（256 字符） | validate 通过则正常处理，否则 2005 |
| 并发知识库创建 | `asyncio.gather` 5 个并发请求，验证数据一致性 |
| 文件名特殊字符 | 中文、空格、全角字符（`ａ`）、路径分隔符（被替换为 `_`） |
| GET /api/docs | 返回 API 文档文本，status 200 |

---

## 4. 前端单元测试（vitest + vue-test-utils）

### 4.1 vitest 配置

```ts
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import path from 'path'
export default defineConfig({
  plugins: [vue()],
  resolve: { alias: { '@': path.resolve(__dirname, '../../front_end/src') } },
  test: { environment: 'jsdom', globals: true },
})
```

需要安装：`vitest`、`@vue/test-utils`、`@vitest/coverage-v8`、`jsdom`

### 4.2 Store 测试

**test_useKnowledgeBase.ts：**
- `getList`：mock `urlResquest.kbList` 返回成功，验证 `knowledgeBaseList` 更新、`showDefault` = normal
- `getList` 空列表：验证 `showDefault` = default
- `getList` 失败：mock throw，验证错误处理
- `setCurrentId` / `setCurrentKbName` / `setSelectList`：验证状态更新
- `setShowDeleteModal`：验证弹窗状态切换

**test_useChat.ts：**
- `clearQAList`：push 数据后清空，验证 `QA_List` 为 `[]`
- 初始状态：`QA_List` 为空、`showModal` 为 false
- localStorage 持久化：验证 persist 配置

**test_useUser.ts：**
- `setUserInfo`：更新 `userInfo` 对象
- localStorage 持久化

**test_useKnowledgeModal.ts：**
- `setModalVisible` / `setUrlModalVisible`：弹窗状态
- `setKnowledgeName` / `setFileList` / `setUrlList`：表单状态
- `getFileList`：mock `urlResquest.fileList`，验证文件列表更新 + `getStatus` 状态映射
- `$reset`：验证所有状态回到初始值

**test_useOptionList.ts：**
- `getDetails`：mock API 返回文件列表，验证 `dataSource` 格式化（`formatFileSize`、`formatDate`）
- 轮询逻辑：mock 返回含 `gray` 状态的文件，验证 setTimeout 轮询触发
- 全部解析完成：mock 无 gray 文件，验证不轮询

### 4.3 工具函数测试

**test_utils.ts：**
| 函数 | 测试用例 |
|------|---------|
| `getStatus` | 各 status 映射：`loading→上传中`、`red→解析失败`、`gray→上传成功待解析`、`green→解析成功`、`yellow→解析失败`、`red + errorText→使用 errorText` |
| `formatFileSize` | `<0→未知`、`500→500B`、`1500→1.46KB`、`1500000→1.43MB`、`1500000000→1.4G` |
| `formatDate` | `"202401091530"→"2024-01-09"`、空串→`""`、自定义分隔符 |
| `resultControl` | `code===200` resolve、`errorCode===0` resolve、其他 reject |
| `throttle` | 快速调用只执行一次、延迟后执行第二次 |
| `getRandomString` | 长度正确、只含合法字符 |
| `isMac` | mock userAgent |

**test_typewriter.ts：**
| 方法 | 测试用例 |
|------|---------|
| `add` | 字符逐个入队、空字符串忽略 |
| `start` / `consume` | 队列有内容时按 dynamicSpeed 消费、回调被调用 |
| `dynamicSpeed` | 队列短时返回 200ms 上限、队列长时速度加快 |
| `done` | 停止消费、剩余字符一次性回调、队列清空 |

**test_resConfig.ts：**
- `checkResStatus.isSuccess(200)` → true
- `checkResStatus.noLogin(401)` → true
- `checkResStatus.noPerssion(403)` → true

---

## 5. 前端 E2E 交互测试（Playwright）

### 5.1 配置

```ts
import { defineConfig } from '@playwright/test'
export default defineConfig({
  baseURL: 'http://localhost:8777',
  testDir: './specs',
  timeout: 60000,       // SSE 流式响应需要较长超时
  use: { locale: 'zh-CN', actionTimeout: 10000 },
})
```

### 5.2 测试用例概要

详细的逐步操作步骤见独立文档 `ui-test-steps.md`。

| 测试文件 | 覆盖流程 | 前置条件 |
|---------|---------|---------|
| `knowledge-base.spec.ts` | 创建→列表→选中→重命名→删除知识库 | 服务已启动 |
| `file-upload.spec.ts` | 上传文件→查看状态→删除文件；URL上传 | 至少一个知识库 |
| `chat.spec.ts` | 选中知识库→输入问题→SSE 流式回答→来源文档→复制→停止→重新生成→清空对话 | 知识库含已解析文件 |
| `startup.spec.ts` | 启动→健康检查→基本操作→SIGTERM 停止→二次启动 | 无 |

**E2E 关键注意点：**
- 前端通过 `fetchEventSource` 发 SSE 请求，Playwright 不能用 `page.waitForResponse` 的普通 JSON 断言，需要监听 SSE stream 或等待 UI 元素变化
- 知识库创建后弹窗自动打开（`AddInput.vue` 的 `addKb` 方法调用 `setModalVisible`），需要处理弹窗
- 文件上传后后台异步解析，状态从 gray → green 需要等待
- 聊天使用 Typewriter 打字机效果，回答是逐步出现的

---

## 6. 启动/停止脚本测试

### 6.1 背景说明

项目没有独立的停止脚本，服务通过 `start.sh` 的 `exec uvicorn` 启动，Ctrl+C 或 SIGTERM 停止。

### 6.2 test_start_sh.sh（bats-core）

| 测试用例 | 说明 |
|---------|------|
| 脚本存在且可执行 | `[ -x start.sh ]` |
| 语法检查 | `bash -n start.sh` 无错误 |
| 必要目录创建 | 运行后 `logs/debug_logs`、`logs/qa_logs`、`BISHON_DB/faiss`、`BISHON_DB/content` 目录存在 |
| conda 环境检测 | 如果 conda 存在则激活（验证 `$CONDA_DEFAULT_ENV`） |
| 依赖安装标记 | 删除 `.deps_installed` 后运行，验证文件被创建 |
| 跳过已安装依赖 | `.deps_installed` 存在时不执行 pip install |
| 服务启动 | `start.sh &` 后等待端口 8777 可连接（`curl` 重试 30s） |
| 服务响应 | `curl http://localhost:8777/api/docs` 返回 200 且含 "Bishon V2" |
| API 功能验证 | 启动后调用 `new_knowledge_base` → `list_knowledge_base` → `delete_knowledge_base` 全流程 |
| 优雅停止 | `kill -TERM $PID` 后进程退出、端口释放 |
| 二次启动 | 停止后再次启动成功，端口可访问 |
| 清理 | 测试结束后删除测试数据（`.deps_installed` 保留） |

**注意：** 此测试需要真实 conda 环境和依赖，标记为 `@slow` 或 `@integration`，CI 中单独运行。

### 6.3 test_start_bat.bat（可选，Windows 环境）

| 测试用例 | 说明 |
|---------|------|
| 脚本存在 | `start.bat` 文件存在 |
| 目录创建 | `logs\debug_logs` 等目录被创建 |
| 硬编码路径问题 | 标记 `<your-conda-path>` 为待修复项，测试中跳过 conda 激活验证 |

---

## 7. 测试依赖

### 后端（`requirements-dev.txt`）

```
pytest>=8.0
pytest-asyncio>=0.23
httpx>=0.27
pytest-cov>=5.0
pytest-timeout>=2.3
```

Shell 脚本测试需要系统安装 `bats-core`：
```bash
npm install -g bats-core   # 或 apt install bats
```

### 前端（`package.json` devDependencies 新增）

```json
{
  "vitest": "^2.0",
  "@vue/test-utils": "^2.4",
  "@vitest/coverage-v8": "^2.0",
  "jsdom": "^24.0",
  "@playwright/test": "^1.44"
}
```

---

## 8. 运行命令

```bash
# === 后端 ===
# 单元测试
pytest tests/backend/unit/ -v

# 集成测试
pytest tests/backend/integration/ -v

# 全部 + 覆盖率
pytest tests/backend/ -v --cov=bishon_kernel --cov-report=html

# === 前端 ===
# 单元测试（在 front_end 目录）
cd front_end && npx vitest run

# E2E（需先启动后端 + 前端构建）
npx playwright test --config=tests/frontend/e2e/playwright.config.ts

# === 脚本 ===
bats tests/scripts/test_start_sh.sh

# === 全部 ===
./run_all_tests.sh
```

---

## 9. 执行优先级

分 3 批实施：

**第一批（核心，立即可做，无外部依赖）：**
1. `conftest.py` — 全局 fixtures（临时 SQLite/FAISS 路径替换）
2. `test_general_utils.py` — 纯函数，零依赖
3. `test_sqlite_client.py` — 数据层基础
4. `test_faiss_client.py` — 向量索引基础
5. API 集成测试 `conftest.py` — TestClient fixture

**第二批（需要 mock 外部服务）：**
6. `test_local_doc_qa.py` — 核心逻辑
7. `test_llm_client.py` / `test_embedding_client.py` / `test_rerank_client.py`
8. `test_local_file.py`
9. `test_api_knowledge_base.py` → `test_api_file_upload.py` → `test_api_chat.py` → `test_api_edge_cases.py`

**第三批（前端 + 脚本）：**
10. 前端 vitest 配置 + `test_utils.ts` + `test_typewriter.ts` + `test_resConfig.ts`
11. Store 测试（5 个 store）
12. Playwright E2E 4 个 spec
13. `test_start_sh.sh`
14. UI 测试步骤文档 `ui-test-steps.md`

---

## 10. 与现有代码的映射

| 测试文件 | 被测源文件 |
|---------|----------|
| `test_general_utils.py` | `bishon_kernel/utils/general_utils.py` |
| `test_sqlite_client.py` | `bishon_kernel/connector/database/sqlite/sqlite_client.py` |
| `test_faiss_client.py` | `bishon_kernel/connector/database/faiss/faiss_client.py` |
| `test_local_doc_qa.py` | `bishon_kernel/core/local_doc_qa.py` |
| `test_local_file.py` | `bishon_kernel/core/local_file.py` |
| `test_llm_client.py` | `bishon_kernel/connector/llm/llm_for_openai_api.py` |
| `test_embedding_client.py` | `bishon_kernel/connector/embedding/openai_embedding.py` |
| `test_rerank_client.py` | `bishon_kernel/connector/rerank/rerank_client.py` |
| `test_api_*.py` | `bishon_kernel/bishon_server/handler.py` + `app.py` |
| `test_useKnowledgeBase.ts` | `front_end/src/store/useKnowledgeBase.ts` |
| `test_useChat.ts` | `front_end/src/store/useChat.ts` |
| `test_useUser.ts` | `front_end/src/store/useUser.ts` |
| `test_useKnowledgeModal.ts` | `front_end/src/store/useKnowledgeModal.ts` |
| `test_useOptionList.ts` | `front_end/src/store/useOptiionList.ts` |
| `test_utils.ts` | `front_end/src/utils/utils.ts` |
| `test_typewriter.ts` | `front_end/src/utils/typewriter.ts` |
| `test_resConfig.ts` | `front_end/src/services/ResConfig.ts` |
| E2E specs | `front_end/src/views/Home.vue` + 全部组件 |
