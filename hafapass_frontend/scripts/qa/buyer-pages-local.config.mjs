import base from '../../playwright.config.js'

// Local shared-workstation allowance: retain every scenario and zero retries,
// but let dev route chunks settle under concurrent project load.
export default {
  ...base,
  testDir: '../../e2e',
  outputDir: '/tmp/hafapass-buyer-pages-local-results',
  expect: { timeout: 15_000 },
  timeout: 60_000,
  workers: 1,
  retries: 0,
}
