import { devices } from '@playwright/test'
import base from '../../playwright.config.js'

export default {
  ...base,
  testDir: '../../e2e',
  testMatch: 'buyer-pages-pass.spec.js',
  outputDir: '/tmp/hafapass-buyer-pages-webkit-results',
  workers: 1,
  projects: [{ name: 'webkit', use: { ...devices['Desktop Safari'] } }],
}
