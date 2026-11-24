import { defineConfig, devices } from '@playwright/test'
export default defineConfig({
  testDir: './e2e', testMatch: 'home-redesign-production.spec.js', workers: 1,
  use: { baseURL: 'http://127.0.0.1:4189', ...devices['Desktop Chrome'] },
  webServer: { command: 'npx vite preview --host 127.0.0.1 --port 4189 --strictPort', url: 'http://127.0.0.1:4189', reuseExistingServer: false },
})
