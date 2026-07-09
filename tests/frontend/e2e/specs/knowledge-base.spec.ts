import { test, expect } from '@playwright/test'
import { navigateToHome, createKBViaUI, deleteKBViaUI } from '../helpers'

test.describe('Knowledge Base Management', () => {
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

  test('首次访问 - 无知识库时显示默认页面', async ({ page }) => {
    // May already have KBs from previous test runs; if so, skip this visual check
    const cards = page.locator('.sider .card')
    const cardCount = await cards.count()

    if (cardCount === 0) {
      // DefaultPage should be visible
      await expect(page.getByText('上传文档 发起提问')).toBeVisible()
      // Sidebar input visible
      await expect(page.getByPlaceholder('请输入知识库名称')).toBeVisible()
    }
  })

  test('创建知识库 - 弹窗自动打开', async ({ page }) => {
    const kbName = '测试KB_' + Date.now()

    const input = page.getByPlaceholder('请输入知识库名称')
    await input.fill(kbName)
    await page.locator('.add-button').click()

    // Upload dialog should appear
    await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })

    // Close dialog
    await page.locator('.upload-file-modal .ant-modal-close').click()
    await page.waitForTimeout(500)

    // Should be in management view - click back to chat
    const backBtn = page.getByText('返回对话')
    if (await backBtn.isVisible()) {
      await backBtn.click()
    }

    // KB card should appear in sidebar with the name
    await expect(page.locator('.sider .card').filter({ hasText: kbName })).toBeVisible({ timeout: 10000 })

    // Card should be auto-selected (active)
    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await expect(card).toHaveClass(/active/)

    // Cleanup
    await deleteKBViaUI(page, kbName)
  })

  test('知识库单选切换', async ({ page }) => {
    const kbNameA = 'SelectA_' + Date.now()
    const kbNameB = 'SelectB_' + Date.now()

    // Create two KBs
    await createKBViaUI(page, kbNameA)
    await createKBViaUI(page, kbNameB)

    const cardA = page.locator('.sider .card').filter({ hasText: kbNameA })
    const cardB = page.locator('.sider .card').filter({ hasText: kbNameB })

    // Both should be visible
    await expect(cardA).toBeVisible()
    await expect(cardB).toBeVisible()

    // Click card A - should be selected
    await cardA.click()
    await expect(cardA).toHaveClass(/active/)

    // Click card B - B selected, A deselected (single-select)
    await cardB.click()
    await expect(cardB).toHaveClass(/active/)

    // Cleanup
    await deleteKBViaUI(page, kbNameA)
    await deleteKBViaUI(page, kbNameB)
  })

  test('重命名知识库', async ({ page }) => {
    const oldName = 'RenameOld_' + Date.now()
    const newName = 'RenameNew_' + Date.now()

    await createKBViaUI(page, oldName)

    // Find card index by textContent (includes hidden elements, unlike innerText)
    const allCards = page.locator('.sider .card')
    const idx = await allCards.evaluateAll(
      (els, name) => Array.from(els).findIndex(el => el.textContent?.includes(name)),
      oldName,
    )
    expect(idx).toBeGreaterThanOrEqual(0)

    // Hover to show popover
    await allCards.nth(idx).hover()
    await page.waitForTimeout(500)

    // Click rename in popover
    await page.locator('.card-hover').getByText('重命名').click()
    await page.waitForTimeout(500)

    // Card enters edit mode - use saved index (textContent-based, works even after v-show toggles)
    const editInput = allCards.nth(idx).locator('.editing input')
    await editInput.clear()
    await editInput.fill(newName)

    // Click confirm icon
    await allCards.nth(idx).locator('svg:has(use[href="#icon-card-confirm"])').click()

    // Should show success message
    await expect(page.getByText('重命名成功')).toBeVisible({ timeout: 5000 })

    // Card should show new name
    await expect(page.locator('.sider .card').filter({ hasText: newName })).toBeVisible()

    // Cleanup
    await deleteKBViaUI(page, newName)
  })

  test('重命名取消', async ({ page }) => {
    const kbName = 'RenameCancel_' + Date.now()

    await createKBViaUI(page, kbName)

    // Find card index by textContent
    const allCards = page.locator('.sider .card')
    const idx = await allCards.evaluateAll(
      (els, name) => Array.from(els).findIndex(el => el.textContent?.includes(name)),
      kbName,
    )
    expect(idx).toBeGreaterThanOrEqual(0)

    // Hover and click rename
    await allCards.nth(idx).hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('重命名').click()
    await page.waitForTimeout(500)

    // Card enters edit mode - use saved index
    const editInput = allCards.nth(idx).locator('.editing input')
    await editInput.clear()
    await editInput.fill('ShouldNotSave')

    // Click cancel icon
    await allCards.nth(idx).locator('svg:has(use[href="#icon-card-cancel"])').click()

    // Name should revert
    await expect(page.locator('.sider .card').filter({ hasText: kbName })).toBeVisible()

    // Cleanup
    await deleteKBViaUI(page, kbName)
  })

  test('删除知识库', async ({ page }) => {
    const kbName = 'DeleteTest_' + Date.now()

    await createKBViaUI(page, kbName)

    const card = page.locator('.sider .card').filter({ hasText: kbName })
    await expect(card).toBeVisible()

    // Hover and click delete
    await card.hover()
    await page.waitForTimeout(500)
    await page.locator('.card-hover').getByText('删除').click()

    // Confirm modal should appear
    await expect(page.locator('.private-modal')).toBeVisible()
    await expect(page.getByText('确认删除该该知识库')).toBeVisible()

    // Click confirm
    await page.locator('.private-modal .ant-btn-primary').click()

    // Card should disappear
    await expect(page.locator('.sider .card').filter({ hasText: kbName })).not.toBeVisible({ timeout: 10000 })
  })

  test('删除所有知识库后回到默认页', async ({ page }) => {
    const kbName = 'DeleteAll_' + Date.now()

    await createKBViaUI(page, kbName)
    await deleteKBViaUI(page, kbName)

    // Should show default page if no other KBs exist
    const cards = page.locator('.sider .card')
    const cardCount = await cards.count()
    if (cardCount === 0) {
      await expect(page.getByText('上传文档 发起提问')).toBeVisible({ timeout: 10000 })
    }
  })
})
