import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import AutoImport from 'unplugin-auto-import/vite'
import path from 'path'

export default defineConfig({
  plugins: [
    AutoImport({
      imports: ['vue', 'vue-router', 'pinia'],
    }),
    vue(),
  ],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
      // Deduplicate: all packages resolve from front_end/node_modules
      pinia: path.resolve(__dirname, 'node_modules/pinia'),
      vue: path.resolve(__dirname, 'node_modules/vue'),
      'vue-router': path.resolve(__dirname, 'node_modules/vue-router'),
      'ant-design-vue': path.resolve(__dirname, 'node_modules/ant-design-vue'),
    },
  },
  server: {
    fs: {
      allow: ['..'],
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['../tests/frontend/vitest.setup.ts'],
    include: ['../tests/frontend/unit/**/*.ts'],
    server: {
      deps: {
        inline: ['pinia', 'vue', 'vue-router'],
      },
    },
  },
})
