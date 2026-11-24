import { defineConfig } from '@playwright/test'
import { env } from 'node:process'
const events = env.HOME_TEST_MODE === 'events'
const baseURL = env.HOME_BASE_URL || `http://127.0.0.1:${events ? 4173 : 4178}`
export default defineConfig({
  outputDir: events ? 'test-results-home-events' : 'test-results-home-demo',
  testDir: './e2e', testMatch: events ? 'home-redesign-events.spec.js' : /home-redesign(?:-demo-events)?\.spec\.js/,
  workers: 2, reporter: 'list',
  use: { baseURL, screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  projects: [
    ...[{ width: 375, height: 667 }, { width: 390, height: 844 }, { width: 430, height: 932 }].map(viewport => ({ name: `webkit-${viewport.width}`, use: { browserName: 'webkit', isMobile: true, hasTouch: true, deviceScaleFactor: 2, viewport } })),
    { name: 'chromium-1440', use: { browserName: 'chromium', viewport: { width: 1440, height: 900 } } },
  ],
})
