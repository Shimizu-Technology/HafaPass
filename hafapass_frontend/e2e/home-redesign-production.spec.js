import { expect, test } from '@playwright/test'
import { prepare, event, config } from '../scripts/qa/buyer-pages-fixtures.mjs'

// This runs against the flag-off production bundle, never the fictional adapter.
test('flag-off checkout creates a mocked pending order and reaches the payment step', async ({ page }) => {
  await prepare(page)
  await page.route('**/api/v1/config', route => route.fulfill({ json: { ...config, payment_mode: 'live', stripe_publishable_key: 'pk_test_synthetic' } }))
  await page.route('**/api/v1/orders', route => route.fulfill({ json: {
    id: 9001, status: 'pending', payment_mode: 'live', client_secret: 'pi_synthetic_secret_test', stripe_publishable_key: 'pk_test_synthetic',
    order_access_token: 'synthetic-access', total_cents: 2725, subtotal_cents: 2500, service_fee_cents: 225, event,
  } }))
  // No provider traffic or real payments. The unchanged provider failure UI is a
  // valid observable payment-step outcome when the external SDK is unavailable.
  await page.route('https://js.stripe.com/**', route => route.abort())
  await page.goto('/events/community-night')
  await page.getByRole('button', { name: 'Increase quantity for General admission', exact: true }).click()
  await page.getByRole('button', { name: /Buy tickets/ }).click()
  await page.getByLabel('Full name').fill('Synthetic Buyer')
  await page.getByLabel('Email address', { exact: true }).fill('buyer@example.invalid')
  await page.locator('#termsAccepted').check()
  await page.getByRole('button', { name: /Continue to payment/ }).click()
  await expect(page.getByRole('heading', { name: 'Payment', exact: true })).toBeVisible()
  await expect(page.getByTestId('demo-payments-off-notice')).toHaveCount(0)
})
