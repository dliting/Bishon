import { test, expect } from '@playwright/test'
import { navigateToHome, uploadFileViaDialog, waitForFileGreen } from '../helpers'

const FILE_CONTENT = `人工智能（Artificial Intelligence，简称AI）是计算机科学的一个分支，致力于开发能够模拟人类智能的系统。
深度学习是机器学习的一种方法，使用多层神经网络来处理复杂的数据模式。
自然语言处理（NLP）使计算机能够理解、解释和生成人类语言。
知识库系统是一种用于存储、组织和检索结构化信息的技术。
向量数据库通过将数据转换为高维向量来实现语义搜索和相似性匹配。`

test.describe('File Upload', () => {
  test.beforeEach(async ({ page }) => {
    await page.route('**/*', async route => {
      await route.continue({
        headers: {
          ...route.request().headers(),
          'Cache-Control': 'no-cache, no-store',
          'Pragma': 'no-cache',
        },
      })
    })
    await navigateToHome(page)
  })

  test('上传文件 - 通过创建KB弹窗', async ({ page }) => {
    const kbName = 'UploadTest_' + Date.now()

    // Create KB - dialog auto-opens
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })

    // Upload file
    await uploadFileViaDialog(page, 'ai_knowledge.txt', FILE_CONTENT)

    // Should now be in management view with file in table
    await expect(page.locator('.ant-table-tbody').getByText('ai_knowledge.txt')).toBeVisible({ timeout: 10000 })

    // Cleanup: delete KB
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
  })

  test('上传后文件状态跟踪', async ({ page }) => {
    const kbName = 'StatusTrack_' + Date.now()

    // Create KB and upload
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await uploadFileViaDialog(page, 'status_test.txt', FILE_CONTENT)

    // File should appear in management table
    const row = page.locator('.ant-table-tbody tr').filter({ hasText: 'status_test.txt' })
    await expect(row).toBeVisible({ timeout: 10000 })

    // Wait for status to become green (parsing succeeded).
    await waitForFileGreen(page, 'status_test.txt')

    // Cleanup
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
  })

  test('通过管理页面上传文件', async ({ page }) => {
    const kbName = 'ManageUpload_' + Date.now()

    // Create KB, close dialog immediately
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await page.locator('.upload-file-modal .ant-modal-close').click()
    await page.waitForTimeout(500)

    // Go to chat first
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }

    // Navigate to manage view
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('管理').click()
    await page.waitForTimeout(500)

    // Click upload button
    await page.locator('.options .upload').click()

    // Upload dialog re-opens
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await uploadFileViaDialog(page, 'manage_upload.txt', FILE_CONTENT)

    // File in table
    await expect(page.locator('.ant-table-tbody').getByText('manage_upload.txt')).toBeVisible({ timeout: 10000 })

    // Cleanup
    await page.getByText('返回对话').click()
    const card2 = page.locator('.sider .card').filter({ hasText: kbName })
    await card2.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
  })

  test('上传网页链接', async ({ page }) => {
    const kbName = 'UrlUpload_' + Date.now()

    // Create KB and go to manage view
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await page.locator('.upload-file-modal .ant-modal-close').click()
    await page.waitForTimeout(500)

    // Click the "添加网址" (add URL) button.
    await page.locator('.options .add-link').click()

    // URL dialog opens
    const urlInput = page.getByPlaceholder('请输入网址')
    await expect(urlInput).toBeVisible({ timeout: 5000 })

    // Fill URL and click add icon
    await urlInput.fill('https://example.com/test-page')
    await page.locator('.upload-file-modal svg:has(use[href="#icon-add"])').click()

    // URL was added to list - verify confirm button is enabled
    // Use .last() because FileUploadDialog's disabled .upload-btn is also in DOM
    const confirmBtn = page.locator('.upload-file-modal .upload-btn').last()
    await expect(confirmBtn).toBeEnabled({ timeout: 5000 })

    // Click confirm
    await confirmBtn.click()
    await page.waitForTimeout(1000)

    // URL should appear in file table
    await expect(page.locator('.ant-table-tbody').getByText('example.com')).toBeVisible({ timeout: 15000 })

    // Cleanup
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
  })

  test('删除文件', async ({ page }) => {
    const kbName = 'DeleteFile_' + Date.now()

    // Create KB and upload
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await uploadFileViaDialog(page, 'to_delete.txt', FILE_CONTENT)

    // File in table
    await expect(page.locator('.ant-table-tbody').getByText('to_delete.txt')).toBeVisible({ timeout: 10000 })

    // Click delete link in table row
    const row = page.locator('.ant-table-tbody tr').filter({ hasText: 'to_delete.txt' })
    await row.locator('.delete-item').click()

    // Confirm popconfirm
    await page.locator('.del-pop .ant-btn-primary').click()

    // File should be removed
    await expect(page.locator('.ant-table-tbody tr').filter({ hasText: 'to_delete.txt' })).not.toBeVisible({ timeout: 5000 })

    // Cleanup
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
  })

  test('返回对话视图', async ({ page }) => {
    const kbName = 'NavTest_' + Date.now()

    // Create KB and go to manage view
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await page.locator('.upload-file-modal .ant-modal-close').click()
    await page.waitForTimeout(500)

    // Click the "返回对话" (back to chat) button.
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }

    // Should see chat input
    await expect(page.getByPlaceholder('请输入问题')).toBeVisible({ timeout: 5000 })

    // Cleanup
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
  })
})
