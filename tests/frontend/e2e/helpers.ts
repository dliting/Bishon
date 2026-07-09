import { Page, expect } from '@playwright/test'

export const BASE_URL = '/bishon/'

export async function navigateToHome(page: Page) {
  await page.goto(BASE_URL, { waitUntil: 'networkidle' })
  await page.waitForTimeout(500)
}

export async function createKBViaUI(page: Page, name: string) {
  const input = page.getByPlaceholder('请输入知识库名称')
  await input.fill(name)
  await page.locator('.add-button').click()
  await expect(page.locator('.upload-file-modal .ant-modal-title')).toContainText('上传文档', { timeout: 10000 })
  await page.locator('.upload-file-modal .ant-modal-close').click()
  await page.waitForTimeout(500)
  const backBtn = page.getByText('返回对话')
  if (await backBtn.isVisible()) {
    await backBtn.click()
  }
}

export async function uploadFileViaDialog(page: Page, fileName: string, content: string) {
  const fileChooserPromise = page.waitForEvent('filechooser')
  await page.locator('.upload-file-modal .before-upload-box').click()
  const fileChooser = await fileChooserPromise
  await fileChooser.setFiles({
    name: fileName,
    mimeType: 'text/plain',
    buffer: Buffer.from(content),
  })
  await expect(page.getByText('上传成功')).toBeVisible({ timeout: 15000 })
  await page.locator('.upload-file-modal .upload-btn').click()
}

export async function waitForFileGreen(page: Page, fileName: string, timeout = 120000) {
  const row = page.locator('.ant-table-tbody tr').filter({ hasText: fileName })
  await expect(row.locator('.status-box span').last()).toContainText('解析成功', { timeout })
}

export async function sendChatQuestion(page: Page, question: string) {
  const input = page.getByPlaceholder('请输入问题')
  await input.fill(question)
  await page.locator('.send-plane button').click()
}

export async function waitForChatResponse(page: Page, timeout = 60000) {
  await expect(page.locator('.feed-back').first()).toBeVisible({ timeout })
}

export async function navigateToManage(page: Page, kbName: string) {
  const card = page.locator('.sider .card').filter({ hasText: kbName })
  await card.hover()
  await page.waitForTimeout(500)
  await page.locator('.card-hover').getByText('管理').click()
  await page.waitForTimeout(500)
}

export async function deleteKBViaUI(page: Page, kbName: string) {
  const card = page.locator('.sider .card').filter({ hasText: kbName })
  await card.hover()
  await page.waitForTimeout(500)
  await page.locator('.card-hover').getByText('删除').click()
  await expect(page.locator('.private-modal')).toBeVisible()
  await page.locator('.private-modal .ant-btn-primary').click()
  await expect(page.locator('.sider .card').filter({ hasText: kbName })).not.toBeVisible({ timeout: 10000 })
}
