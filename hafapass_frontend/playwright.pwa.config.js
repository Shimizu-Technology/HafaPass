import { defineConfig, devices } from '@playwright/test'

// A real service worker requires production builds, separate from the dev suite.
export default defineConfig({
  testDir: './e2e-pwa',
  workers: 1,
  timeout: 180_000,
  use: { ...devices['Desktop Chrome'], baseURL: 'http://127.0.0.1:5234', actionTimeout: 15_000, navigationTimeout: 15_000, trace: 'retain-on-failure' },
})
