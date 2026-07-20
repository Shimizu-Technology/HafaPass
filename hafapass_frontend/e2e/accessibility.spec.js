import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

test('buyer policy and consent surfaces have no serious automated accessibility violations', async ({ page }) => {
  await page.route('**/api/v1/health', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ status: 'ok' }),
  }))
  await page.route('**/api/v1/config', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({
      buyer_terms_version: 'test-version',
      policies: {
        'buyer-terms': {
          title: 'Buyer Terms',
          summary: 'Test summary',
          sections: [{ heading: 'Your purchase', body: 'Test policy content.' }],
        },
      },
    }),
  }))
  await page.goto('/policies/buyer-terms')
  await expect(page.getByRole('heading', { level: 1, name: 'Buyer Terms' })).toBeVisible()

  const results = await new AxeBuilder({ page }).analyze()
  const blocking = results.violations.filter(violation => ['serious', 'critical'].includes(violation.impact))
  expect(blocking).toEqual([])

  await page.keyboard.press('Tab')
  const focused = page.locator(':focus')
  await expect(focused).toBeVisible()
})
