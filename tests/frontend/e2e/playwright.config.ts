import { defineConfig } from '@playwright/test'
export default defineConfig({
  testDir: './specs',
  timeout: 60000,
  workers: 1,
  use: {
    baseURL: 'http://localhost:8777',
    locale: 'zh-CN',
    actionTimeout: 10000,
    screenshot: 'only-on-failure',
    extraHTTPHeaders: {
      'Cache-Control': 'no-cache',
    },
  },
})
