# Bishon V2 UI 交互测试步骤手册

> 可用于手工回归测试和 Playwright E2E 自动化测试的编写参考。
> 前置条件：后端服务运行在 `http://localhost:8777`，前端已构建并挂载到 `/bishon/`。

---

## 环境

| 项目 | 值 |
|------|---|
| 后端地址 | `http://localhost:8777` |
| 前端地址 | `http://localhost:8777/bishon/` |
| 测试用户 | `default_user`（硬编码在 `urlConfig.ts` 的 `userId`） |
| 浏览器 | Chrome 120+ |

## 测试文件映射

| 流程 | Playwright Spec | 测试名称 |
|------|-----------------|---------|
| 1 - 首次访问 | `knowledge-base.spec.ts` | 首次访问 - 无知识库时显示默认页面 |
| 2 - 创建知识库 | `knowledge-base.spec.ts` | 创建知识库 - 弹窗自动打开 |
| 3 - 上传文件 | `file-upload.spec.ts` | 上传文件 - 通过创建KB弹窗 |
| 4 - URL上传 | `file-upload.spec.ts` | 上传网页链接 |
| 5 - 问答 | `chat.spec.ts` | 流式问答完整流程 |
| 6 - 多轮对话 | `chat.spec.ts` | 多轮对话切换 (test.step) |
| 7 - 清空/下载 | `chat.spec.ts` | 下载会话图片 / 清空会话 (test.step) |
| 8 - 重命名 | `knowledge-base.spec.ts` | 重命名知识库 |
| 9 - 删除知识库 | `knowledge-base.spec.ts` | 删除知识库 |
| 10 - 文件管理 | `file-upload.spec.ts` | 删除文件 |
| 11 - 选中/取消 | `knowledge-base.spec.ts` | 知识库单选切换 |
| 12 - 生命周期 | `startup.spec.ts` | 完整生命周期 UI 流程 |

> **注意**: `get_total_status` 和 `clean_files_by_status` 是后端专用 API，无对应 UI，不在前端交互测试范围内。

---

## 流程 1：首次访问（无知识库）

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 打开 `http://localhost:8777/bishon/` | 页面加载完成，显示 "Bishon 知识库问答" 标题 |
| 2 | 检查页面主体区域 | 显示默认上传页面（`DefaultPage` 组件），含 "上传文档 发起提问" 提示 |
| 3 | 检查左侧侧边栏 | 显示 "新建" 输入框，无知识库卡片 |
| 4 | 检查上传区域 | 显示 "上传文档 发起提问" 和支持格式说明 |

### Playwright 要点

```ts
await page.goto('/bishon/', { waitUntil: 'networkidle' })
await expect(page.getByText('上传文档 发起提问')).toBeVisible()
await expect(page.getByPlaceholder('请输入知识库名称')).toBeVisible()
await expect(page.locator('.sider .card')).toHaveCount(0)
```

---

## 流程 2：创建知识库

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 在侧边栏 "新建" 输入框中输入知识库名称 | 输入框显示文字 |
| 2 | 点击输入框右侧的 "新建" 按钮 | API 调用 `POST /api/local_doc_qa/new_knowledge_base` |
| 3 | 等待响应 | 弹出文件上传对话框（`FileUploadDialog`） |
| 4 | 关闭对话框 | 进入文件管理视图（OptionList） |
| 5 | 点击 "返回对话" | 回到聊天视图 |
| 6 | 检查侧边栏 | 出现新知识库卡片，名称正确，默认被选中（紫色高亮） |

### Playwright 要点

```ts
await page.getByPlaceholder('请输入知识库名称').fill('测试KB')
await page.locator('.add-button').click()
await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档')
await page.locator('.upload-file-modal .ant-modal-close').click()
await page.getByText('返回对话').click()
await expect(page.locator('.sider .card').filter({ hasText: '测试KB' })).toBeVisible()
await expect(page.locator('.sider .card').filter({ hasText: '测试KB' })).toHaveClass(/active/)
```

> **注意**: `DefaultPage` 上的上传区域点击会自动创建名为 "默认知识库" 的 KB（`Defaultpage.vue:53`），与侧边栏输入不同。

---

## 流程 3：上传文件

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | （延续流程 2）上传弹窗已打开 | 显示 "上传文档" 标题和拖拽区域 |
| 2 | 点击上传区域，选择文件 | 文件选择器弹出 |
| 3 | 选择文件并确认 | 文件出现在上传列表，状态为 "上传中" |
| 4 | 等待上传完成 | 状态变为 "上传成功" |
| 5 | 点击 "确定" 按钮 | 弹窗关闭，进入文件管理视图 |
| 6 | 检查文件列表 | 文件出现在表格中 |
| 7 | 等待后台解析 | 状态从 "解析中" 变为 "解析成功"（store 自动每 10 秒轮询） |

### Playwright 要点

```ts
const fileChooserPromise = page.waitForEvent('filechooser')
await page.locator('.upload-file-modal .before-upload-box').click()
const fileChooser = await fileChooserPromise
await fileChooser.setFiles({ name: 'test.txt', mimeType: 'text/plain', buffer: Buffer.from(content) })
await expect(page.getByText('上传成功')).toBeVisible({ timeout: 15000 })
await page.locator('.upload-file-modal .upload-btn').click()
await expect(page.locator('.ant-table-tbody').getByText('test.txt')).toBeVisible()
```

---

## 流程 4：URL 上传

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 在管理视图，点击 "添加网址" | 弹出 URL 上传对话框 |
| 2 | 在输入框中输入 URL | 输入框显示 URL |
| 3 | 点击添加图标 | URL 出现在列表中 |
| 4 | 点击 "确定" | URL 提交，对话框关闭 |
| 5 | 检查文件列表 | URL 出现在文件表格中 |

### Playwright 要点

```ts
await page.locator('.options .add-link').click()
await page.getByPlaceholder('请输入网址').fill('https://example.com')
await page.locator('svg:has(use[href="#icon-add"])').click()
await page.locator('.upload-file-modal .upload-btn').click()
await expect(page.locator('.ant-table-tbody').getByText('example.com')).toBeVisible({ timeout: 15000 })
```

---

## 流程 5：知识库问答（SSE 流式）

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 从文件管理视图返回对话视图 | 点击 "返回对话" |
| 2 | 确保至少一个知识库被选中（紫色高亮） | 侧边栏知识库卡片高亮 |
| 3 | 在底部输入框输入问题 | 输入框显示文字 |
| 4 | 按 Enter 或点击发送按钮 | 发送 SSE 请求到 `/api/local_doc_qa/local_doc_chat`（`streaming: true`） |
| 5 | 观察回答区域 | 用户问题气泡出现，AI 回答逐字显示（打字机效果） |
| 6 | 等待回答完成 | 闪烁光标消失，显示工具栏（重新生成、复制、点赞、点踩） |
| 7 | 检查来源文档 | 回答下方显示 "数据来源" 和文件名、相关性分数 |

### Playwright 要点

```ts
await page.getByPlaceholder('请输入问题').fill('什么是人工智能？')
await page.locator('.send-plane button').click()
await expect(page.locator('.chat .user .question-text')).toContainText('什么是人工智能')
await expect(page.locator('.feed-back').first()).toBeVisible({ timeout: 60000 })
```

---

## 流程 6：多轮对话控制

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 检查输入框左侧控制按钮 | 显示 "多轮对话" 开关，默认开启（紫色边框 `.control-true`） |
| 2 | 点击控制按钮 | 按钮变为灰色边框（`.control-false`） |
| 3 | 再次点击 | 重新开启多轮对话（`.control-true`） |

### Playwright 要点

```ts
const toggle = page.locator('.control').first()
await expect(toggle).toHaveClass(/control-true/)
await toggle.click()
await expect(toggle).toHaveClass(/control-false/)
await toggle.click()
await expect(toggle).toHaveClass(/control-true/)
```

---

## 流程 7：清空对话和下载

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 点击输入框左侧的下载图标 | 弹出确认框 "是否将会话保存为图片" |
| 2 | 点击确定 | 浏览器下载 chat-shot.png |
| 3 | 点击输入框左侧的删除图标 | 弹出确认框 "清空会话？" |
| 4 | 点击确定 | 所有对话清空 |

### Playwright 要点

```ts
// 下载
await page.locator('.download').first().click()
await expect(page.getByText('是否将会话保存为图片')).toBeVisible()
await page.locator('.private-modal .ant-btn-primary').click()

// 清空
await page.locator('.question-box .delete').first().click()
await expect(page.getByText('清空会话')).toBeVisible()
await page.locator('.private-modal .ant-btn-primary').click()
await expect(page.locator('.chat .user')).toHaveCount(0)
```

---

## 流程 8：重命名知识库

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | hover 侧边栏知识库卡片 | 显示操作菜单（管理/重命名/删除） |
| 2 | 点击 "重命名" | 卡片名称变为输入框，显示确认/取消图标 |
| 3 | 修改名称 | 输入框显示新名称 |
| 4 | 点击确认图标 | API 调用 `POST /api/local_doc_qa/rename_knowledge_base`，显示 "重命名成功" |
| 5 | 检查卡片 | 显示新名称 |
| 6 | 再次重命名，点击取消图标 | 名称恢复原值 |

### Playwright 要点

```ts
const card = page.locator('.sider .card').filter({ hasText: '旧名称' })
await card.hover()
await page.waitForTimeout(500)
await page.getByText('重命名').click()
await card.locator('.editing input').clear()
await card.locator('.editing input').fill('新名称')
await card.locator('svg:has(use[href="#icon-card-confirm"])').click()
await expect(page.getByText('重命名成功')).toBeVisible()
```

---

## 流程 9：删除知识库

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | hover 侧边栏知识库卡片 | 显示操作菜单 |
| 2 | 点击 "删除" | 弹出确认删除弹窗（`DeleteModal`），显示 "确认删除该该知识库？删除后无法恢复" |
| 3 | 点击确定 | API 调用 `POST /api/local_doc_qa/delete_knowledge_base`，显示 "删除成功" |
| 4 | 检查侧边栏 | 知识库卡片消失 |
| 5 | 删除所有知识库 | 页面回到默认上传页面（流程 1 状态） |

### Playwright 要点

```ts
const card = page.locator('.sider .card').filter({ hasText: '名称' })
await card.hover()
await page.waitForTimeout(500)
await page.getByText('删除').click()
await expect(page.locator('.private-modal')).toBeVisible()
await page.locator('.private-modal .ant-btn-primary').click()
await expect(card).not.toBeVisible({ timeout: 10000 })
```

---

## 流程 10：文件管理（删除文件）

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | hover 知识库卡片，点击 "管理" | 进入文件管理视图，显示文件表格 |
| 2 | 点击某文件的删除操作 | 弹出确认框 "确认删除文档吗？" |
| 3 | 点击确定 | 文件从列表消失 |
| 4 | 点击 "返回对话" | 回到聊天视图 |

### Playwright 要点

```ts
const row = page.locator('.ant-table-tbody tr').filter({ hasText: 'file.txt' })
await row.locator('.delete-item').click()
await page.locator('.del-pop .ant-btn-primary').click()
await expect(row).not.toBeVisible()
```

---

## 流程 11：选中/取消选中知识库

> **重要更正**: `SiderCard` 是**单选**模式（`selectList.value = [id]`），点击卡片会替换当前选择，不会累加。

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 点击一个知识库卡片 | 卡片变为紫色高亮（选中状态） |
| 2 | 点击另一个知识库卡片 | 新卡片高亮，原卡片取消高亮（单选替换） |
| 3 | 再次点击同一卡片 | 该卡片仍保持选中（不会取消选择） |

### Playwright 要点

```ts
await cardA.click()
await expect(cardA).toHaveClass(/active/)
await cardB.click()
await expect(cardB).toHaveClass(/active/)
// cardA no longer has active class (single-select replaces)
```

---

## 流程 12：完整生命周期

### 步骤

| # | 操作 | 预期结果 |
|---|------|---------|
| 1 | 打开页面 | 页面正常加载 |
| 2 | 创建知识库 | 知识库出现在侧边栏 |
| 3 | 上传文件并等待解析 | 文件状态变为 "解析成功" |
| 4 | 发起问答 | SSE 流式回答正常 |
| 5 | 进入管理页面，删除文件 | 文件从列表消失 |
| 6 | 删除知识库 | 卡片消失 |
| 7 | 回到默认页面 | 无知识库时显示上传提示 |

---

## 附录：API 端点速查

| 端点 | 方法 | 说明 | UI 触发方式 |
|------|------|------|------------|
| `/api/local_doc_qa/new_knowledge_base` | POST | 新建知识库 | 点击侧边栏 "新建" 按钮 |
| `/api/local_doc_qa/list_knowledge_base` | POST | 知识库列表 | 页面加载自动调用 |
| `/api/local_doc_qa/upload_files` | POST | 上传文件 | 上传对话框选择文件 |
| `/api/local_doc_qa/upload_weblink` | POST | 上传 URL | 管理页 "添加网址" |
| `/api/local_doc_qa/list_files` | POST | 文件列表 | 进入管理视图自动调用 |
| `/api/local_doc_qa/local_doc_chat` | POST | 问答（SSE） | 聊天输入框发送问题 |
| `/api/local_doc_qa/delete_knowledge_base` | POST | 删除知识库 | hover 卡片 → "删除" |
| `/api/local_doc_qa/delete_files` | POST | 删除文件 | 管理页文件行 "删除" |
| `/api/local_doc_qa/rename_knowledge_base` | POST | 重命名知识库 | hover 卡片 → "重命名" |
| `/api/local_doc_qa/get_total_status` | POST | 状态总览 | **无 UI** |
| `/api/local_doc_qa/clean_files_by_status` | POST | 按状态清理 | **无 UI** |
| `/api/docs` | GET | API 文档 | 直接访问 |
