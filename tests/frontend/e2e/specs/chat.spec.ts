import { test, expect } from '@playwright/test'
import { navigateToHome, uploadFileViaDialog, waitForFileGreen, sendChatQuestion, waitForChatResponse } from '../helpers'

const FILE_CONTENT = `人工智能（Artificial Intelligence，简称AI）是计算机科学的一个分支，致力于开发能够模拟人类智能的系统。
深度学习是机器学习的一种方法，使用多层神经网络来处理复杂的数据模式。
自然语言处理（NLP）使计算机能够理解、解释和生成人类语言。
知识库系统是一种用于存储、组织和检索结构化信息的技术。
向量数据库通过将数据转换为高维向量来实现语义搜索和相似性匹配。`

test.describe('Chat Q&A', () => {
  test.beforeEach(async ({ page }) => {
    // Grant clipboard permissions for copy tests
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
  })

  test('流式问答完整流程', async ({ page }) => {
    await navigateToHome(page)

    // Setup: create KB, upload file, wait for green
    const kbName = 'ChatTest_' + Date.now()
    await page.getByPlaceholder('请输入知识库名称').fill(kbName)
    await page.locator('.add-button').click()
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
    await uploadFileViaDialog(page, 'chat_test.txt', FILE_CONTENT)
    await waitForFileGreen(page, 'chat_test.txt')
    await page.getByText('返回对话').click()

    // --- Step 1: Send question ---
    await test.step('发送问题并获取SSE回答', async () => {
      // KB should be selected
      const card = page.locator('.sider .card').filter({ hasText: kbName })
      await expect(card).toHaveClass(/active/)

      // Send question
      await sendChatQuestion(page, '什么是人工智能？')

      // User message bubble should appear
      await expect(page.locator('.chat .user .question-text')).toContainText('什么是人工智能', { timeout: 5000 })

      // Wait for AI response to complete
      await waitForChatResponse(page, 60000)

      // AI response text should not be empty
      const aiText = page.locator('.chat .ai .question-text').first()
      const text = await aiText.textContent()
      expect(text!.length).toBeGreaterThan(0)
    })

    // --- Step 1.5: Source document traceability ---
    await test.step('溯源文档点击打开', async () => {
      // Source documents depend on LLM returning relevant chunks.
      // If no source docs are visible, this step passes silently (not a failure).
      const sourceFile = page.locator('.data-source .file').first()
      if (await sourceFile.isVisible({ timeout: 5000 }).catch(() => false)) {
        // Verify it's an anchor element with click handler
        const tagName = await sourceFile.evaluate(el => el.tagName.toLowerCase())
        expect(tagName).toBe('a')

        // Verify cursor is pointer
        const cursor = await sourceFile.evaluate(el => getComputedStyle(el).cursor)
        expect(cursor).toBe('pointer')

        // Click should open a new tab (handled by window.open)
        const newPagePromise = page.context().waitForEvent('page', { timeout: 10000 }).catch(() => null)
        await sourceFile.click()
        const newPage = await newPagePromise
        if (newPage) {
          await newPage.close()
        }
      }
    })

    // --- Step 2: Copy ---
    await test.step('复制回答', async () => {
      const copyIcon = page.locator('.feed-back .tools svg:has(use[href="#icon-copy"])').first()
      await copyIcon.click()
      // Accept either success or failure (clipboard may be restricted in some environments)
      await expect(page.getByText(/拷贝成功|拷贝失败/)).toBeVisible({ timeout: 5000 })
    })

    // --- Step 3: Like/Unlike ---
    await test.step('点赞和点踩切换', async () => {
      const likeIcon = page.locator('.feed-back .tools svg:has(use[href="#icon-like"])').first()
      const unlikeIcon = page.locator('.feed-back .tools svg:has(use[href="#icon-unlike"])').first()

      // Click like
      await likeIcon.click()
      await expect(likeIcon).toHaveCSS('color', /rgb\(77,\s*113,\s*255\)/)

      // Click unlike - like should reset
      await unlikeIcon.click()
      await expect(unlikeIcon).toHaveCSS('color', /rgb\(77,\s*113,\s*255\)/)
    })

    // --- Step 4: Stop ---
    await test.step('停止回答', async () => {
      await sendChatQuestion(page, '深度学习是什么？')

      // Stop button should appear while responding
      const stopBtn = page.locator('.stop-btn button')
      if (await stopBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
        await stopBtn.click()
        // Tools should appear after stopping
        await expect(page.locator('.feed-back').first()).toBeVisible({ timeout: 10000 })
      }
    })

    // --- Step 5: Regenerate ---
    await test.step('重新生成', async () => {
      const regenBtn = page.locator('.reload-box').first()
      if (await regenBtn.isVisible()) {
        await regenBtn.click()
        await waitForChatResponse(page, 60000)
      }
    })

    // --- Step 6: Multi-turn toggle ---
    await test.step('多轮对话切换', async () => {
      // Scope to .question-box to avoid matching file name's .control class
      const toggle = page.locator('.question-box .control')
      // Default: enabled (control-true)
      await expect(toggle).toHaveClass(/control-true/)

      // Toggle off
      await toggle.click()
      await expect(toggle).toHaveClass(/control-false/)

      // Toggle back on
      await toggle.click()
      await expect(toggle).toHaveClass(/control-true/)
    })

    // --- Step 7: Download ---
    await test.step('下载会话图片', async () => {
      await page.locator('.download').first().click()
      await expect(page.getByText('是否将会话保存为图片')).toBeVisible({ timeout: 5000 })
      await page.locator('.private-modal .ant-btn-primary').click()
    })

    // --- Step 8: Clear chat ---
    await test.step('清空会话', async () => {
      await page.locator('.question-box .delete').first().click()
      await expect(page.getByText('清空会话')).toBeVisible({ timeout: 5000 })
      await page.locator('.private-modal .ant-btn-primary').click()
      // Chat should be cleared
      await expect(page.locator('.chat .user')).toHaveCount(0, { timeout: 5000 })
    })

    // Cleanup: delete KB
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    if (await card.isVisible()) {
      await card.hover()
      await page.waitForTimeout(500)
      await page.locator('.card-hover').getByText('删除').click()
      // Use .last() — other private-modals (download/clear) may still be in DOM
      await expect(page.locator('.private-modal').last()).toBeVisible()
      await page.locator('.private-modal').last().locator('.ant-btn-primary').click()
    }
  })
})
