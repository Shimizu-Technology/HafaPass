import { env } from 'node:process'
import { defineConfig, devices } from '@playwright/test'

const port = Number(env.PLAYWRIGHT_DEMO_PORT || 4178)
const externalBaseURL = env.DEMO_PREVIEW_BASE_URL
const baseURL = externalBaseURL || `http://127.0.0.1:${port}`

export default defineConfig({
  testDir: './e2e',
  testMatch: /(demo-preview|mockup-motion-[abcde])\.spec\.js/,
  fullyParallel: true,
  retries: 0,
  reporter: 'list',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
  ...(externalBaseURL
    ? {}
    : {
        webServer: {
          command: `npx vite preview --host 127.0.0.1 --port ${port} --strictPort`,
          url: baseURL,
          reuseExistingServer: false,
          timeout: 60_000,
        },
      }),
})
