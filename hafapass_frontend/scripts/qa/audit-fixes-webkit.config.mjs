import { defineConfig, devices } from '@playwright/test'
import base from '../../playwright.config.js'
export default defineConfig({
  ...base,
  testDir: new URL('../../e2e/', import.meta.url).pathname,
  testMatch: 'audit-fixes.spec.js',
  workers: 1,
  projects: [{ name: 'webkit', use: { ...devices['Desktop Safari'] } }],
})
