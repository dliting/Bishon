import { test, expect } from '@playwright/test'
import { navigateToHome, uploadFileViaDialog, waitForFileGreen, sendChatQuestion, waitForChatResponse } from '../helpers'

const FILE_CONTENT = `人工智能（Artificial Intelligence，简称AI）是计算机科学的一个分支，致力于开发能够模拟人类智能的系统。
深度学习是机器学习的一种方法，使用多层神经网络来处理复杂的数据模式。
自然语言处理（NLP）使计算机能够理解、解释和生成人类语言。`

test.describe('Service Lifecycle', () => {
  test('健康检查 - API文档可访问', async ({ page }) => {
    const resp = await page.request.get('/api/docs')
    expect(resp.ok()).toBeTruthy()
    const text = await resp.text()
    expect(text).toContain('Bishon V2')
  })

  test('前端页面加载无错误', async ({ page }) => {
    const errors: string[] = []
    page.on('console', msg => {
      if (msg.type() === 'error') {
        errors.push(msg.text())
      }
    })

    await navigateToHome(page)
    // Page should load (DefaultPage or Chat)
    const body = page.locator('body')
    await expect(body).toBeVisible()

    // Filter out known non-critical errors (e.g. favicon, _czc analytics)
    const criticalErrors = errors.filter(e =>
      !e.includes('favicon') && !e.includes('_czc') && !e.includes('Failed to fetch')
    )
    expect(criticalErrors).toHaveLength(0)
  })

  test('完整生命周期 UI 流程', async ({ page }) => {
    test.setTimeout(180000)
    await page.context().grantPermissions(['clipboard-read', 'clipboard-write'])
    await page.route('**/*', async route => {
      await route.continue({
        headers: {
          ...route.request().headers(),
          'Cache-Control': 'no-cache, no-store',
          'Pragma': 'no-cache',
        },
      })
    })

    // Step 1: Navigate to home
    await navigateToHome(page)

    // Step 2: Create KB
    const kbName = 'Lifecycle_' + Date.now()
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })

    // Step 3: Upload file
    await uploadFileViaDialog(page, 'lifecycle_test.txt', FILE_CONTENT)

    // Step 4: Wait for file green status
    await waitForFileGreen(page, 'lifecycle_test.txt')

    // Step 5: Return to chat and ask question
    await page.getByText('返回对话').click()
    // Wait for chat view to load and KB to be selected
    await expect(page.getByPlaceholder('请输入问题')).toBeVisible({ timeout: 10000 })
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await expect(card).toHaveClass(/active/)

    await sendChatQuestion(page, '什么是人工智能？')
    await waitForChatResponse(page, 90000)

    // Verify response
    const aiText = page.locator('.chat .ai .question-text').first()
    const text = await aiText.textContent()
    expect(text!.length).toBeGreaterThan(0)

    // Step 6: Navigate to manage, delete file
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('管理').click()
    await page.waitForTimeout(500)

    // Delete file
    const row = page.locator('.ant-table-tbody tr').filter({ hasText: 'lifecycle_test.txt' })
    await row.locator('.delete-item').click()
    await page.locator('.del-pop .ant-btn-primary').click()
    await expect(page.locator('.ant-table-tbody tr').filter({ hasText: 'lifecycle_test.txt' })).not.toBeVisible({ timeout: 5000 })

    // Step 7: Go back and delete KB
    await page.getByText('返回对话').click()
    const card2 = page.locator('.sider .card').filter({ hasText: kbName })
    await card2.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()
    await expect(page.locator('.private-modal')).toBeVisible()
    await page.locator('.private-modal .ant-btn-primary').click()
    await expect(page.locator('.sider .card').filter({ hasText: kbName })).not.toBeVisible({ timeout: 10000 })
  })
})
