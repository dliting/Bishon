# 文档溯源功能设计

## Context

用户在知识库问答时，AI 返回的答案附带来源文档片段（source_documents），但目前只能展开查看匹配的文本片段，无法打开原始文档查看完整内容。本功能让用户点击来源文档的文件名，即可下载原始文件。

## 需求

- 在 Chat 页面的来源文档区域，点击文件名可打开原始文档
- 文件类型文档（pdf、docx、txt、图片等）通过服务器 API 获取
- URL 类型来源直接在新标签页打开原始链接
- 浏览器触发文件下载（Content-Disposition: attachment），用户可在本地打开查看

## 数据流分析

`file_id` 已存在于完整链路中：

1. 文档处理时 (`local_file.py:124`)：每个 doc chunk 的 metadata 注入 `file_id`
2. 向量搜索时 (`faiss_client.py:207`)：搜索结果包含 `file_id`
3. API 响应时 (`general_utils.py:43`)：`format_source_documents` 包含 `file_id`
4. 前端类型 (`types.ts:14`)：`IDataSourceItem` 已有 `file_id` 字段
5. 前端接收 (`Chat.vue:313-314`)：source_documents 直接赋给 item.source

## 后端设计

### 新增 API 端点

```
GET /api/local_doc_qa/download_file/{file_id}
```

#### 处理流程

1. 通过 `file_id` 查询 File 表 JOIN KnowledgeBase 表，获取 `user_id`、`file_name`、`deleted` 状态
2. 校验文件存在且未删除
3. **URL 类型**（file_name 以 http 开头）：返回 302 重定向到原始 URL
4. **文件类型**：拼接磁盘路径 `UPLOAD_ROOT_PATH / user_id / file_id / file_name`，用 `FileResponse(path, filename=file_name)` 返回。传入 `filename` 参数使 Starlette 自动设置 `Content-Disposition: attachment` 头，浏览器将触发下载而非内联预览

#### 新增 SQLite 查询方法

在 `KnowledgeBaseManager` 中新增：

```python
def get_file_download_info(self, file_id):
    """返回 list[tuple(user_id, file_name, deleted)]，空列表表示未找到"""
    query = """
        SELECT u.user_id, f.file_name, f.deleted
        FROM File f
        JOIN KnowledgeBase kb ON f.kb_id = kb.kb_id
        JOIN User u ON kb.user_id = u.user_id
        WHERE f.file_id = ?
    """
    return self._execute(query, (file_id,), fetch=True)
```

#### 文件路径构建

```python
file_path = os.path.join(UPLOAD_ROOT_PATH, user_id, file_id, file_name)
```

与上传时的路径逻辑一致（handler.py:195）。

### 错误处理

| 情况 | HTTP 状态码 | 响应 |
|------|------------|------|
| file_id 不存在 | 404 | `{"code": 2004, "msg": "file not found"}` |
| 文件已删除 | 404 | `{"code": 2004, "msg": "file deleted"}` |
| file_name 为空或 None | 404 | `{"code": 2004, "msg": "invalid file name"}` |
| 磁盘文件丢失 | 404 | `{"code": 2004, "msg": "file not found on disk"}` |
| URL 类型文件 | 302 | 重定向到原始 URL |

### 安全性

- file_id 为 128-bit 随机 UUID hex，不可枚举
- 内网应用，不做过度安全防护（符合 CLAUDE.md 指导原则）

## 前端设计

### Chat.vue 模板改动

将来源文档的文件名 span 改为可点击元素：

```html
<!-- 原: -->
<span class="file">{{ sourceItem.file_name }}</span>

<!-- 改为: -->
<a class="file" @click="openSourceFile(sourceItem)">{{ sourceItem.file_name }}</a>
```

### 新增方法

```typescript
// apiBase 已在 Chat.vue 中 import，值为 VITE_APP_API_HOST + VITE_APP_API_PREFIX
// aDownLoad 使用 <a download> 触发下载，不会打开空白标签页
const openSourceFile = (sourceItem: IDataSourceItem) => {
  if (!sourceItem.file_name) return;
  if (sourceItem.file_name.startsWith('http')) {
    window.open(sourceItem.file_name, '_blank');
  } else if (sourceItem.file_id) {
    aDownLoad(`${apiBase}/local_doc_qa/download_file/${sourceItem.file_id}`, sourceItem.file_name);
  }
};
```

### 样式改动

`.file` 类添加 `cursor: pointer` 和下划线样式，表示可点击。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `bishon_kernel/bishon_server/handler.py` | 新增 `download_file` 端点 |
| `bishon_kernel/connector/database/sqlite/sqlite_client.py` | 新增 `get_file_download_info` 方法 |
| `front_end/src/components/Chat.vue` | 文件名添加点击事件、样式（使用 `apiBase` 拼接 URL） |
| `docs/API.md` | 更新 API 文档 |

## 测试

### 后端测试

- **单元测试** (`test_handler.py`): 测试 `download_file` 端点正常下载、file_id 不存在、文件已删除、URL 类型重定向、磁盘文件丢失
- **集成测试**: 上传文件 → 调用下载 API（通过 file_id）→ 验证返回内容与上传内容一致（不需要 LLM）

### 前端测试

- **Playwright E2E**: 问答后在来源文档区域点击文件名，验证触发文件下载

### 边界情况

- file_id 为空字符串或非法格式
- 文件在问答后被删除
- URL 类型的来源文档
- 特殊字符文件名（中文、空格等）
