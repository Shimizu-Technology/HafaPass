import { defineConfig, devices } from '@playwright/test'
import process from 'node:process'

// A real service worker requires production builds, separate from the dev suite.
export default defineConfig({
  testDir: './e2e-pwa',
  outputDir: 'test-results-pwa',
  workers: 1,
  reporter: [['list'], ['html', { outputFolder: 'playwright-pwa-report', open: 'never' }]],
  timeout: 180_000,
  projects: [{ name: process.env.PWA_BROWSER || 'chromium', use: {
    ...devices[process.env.PWA_BROWSER === 'webkit' ? 'Desktop Safari' : 'Desktop Chrome'],
  } }],
  use: { baseURL: 'http://127.0.0.1:5234', actionTimeout: 15_000, navigationTimeout: 15_000, trace: 'retain-on-failure' },
})
