import { expect, test } from '@playwright/test'

function json(route, body, status = 200) {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
}

test.beforeEach(async ({ page }) => {
  await page.route('**/api/v1/health', route => json(route, { status: 'ok' }))
})

test('owner can review team roles, Guam payout gates, and create an invitation', async ({ page }) => {
  await page.route('**/api/v1/organizer/organization', route => json(route, {
    id: 7, name: 'Island Events', role: 'owner', payout_ready: false, timezone: 'Pacific/Guam'
  }))
  await page.route('**/api/v1/organizer/memberships', route => {
    if (route.request().method() === 'POST') return json(route, {
      id: 2, email: 'finance@example.com', role: 'finance', status: 'invited', invitation_token: 'browser-signed-token'
    }, 201)
    return json(route, [{ id: 1, email: 'owner@example.com', name: 'Island Owner', role: 'owner', status: 'active' }])
  })
  await page.route('**/api/v1/organizer/connected_accounts', route => json(route, []))

  await page.goto('/dashboard/settings')

  await expect(page.getByRole('heading', { name: 'Island Events' })).toBeVisible()
  await expect(page.getByText(/Blocked unless Stripe confirms Guam/)).toBeVisible()
  await page.getByLabel('Teammate email').fill('finance@example.com')
  await page.getByLabel('Team role').selectOption('finance')
  await page.getByRole('button', { name: 'Invite' }).click()
  await expect(page.getByText('Secure invitation link')).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Invitation link' })).toHaveValue(/browser-signed-token/)
})

test('finance dashboard separates ticket economics and immutable payout state', async ({ page }) => {
  await page.route('**/api/v1/organizer/events/42/stats', route => json(route, {
    total_tickets_sold: 1,
    total_revenue_cents: 5250,
    tickets_checked_in: 0,
    tickets_by_type: [{ name: 'General Admission', sold: 1, available: 9, revenue_cents: 5000 }],
    recent_orders: []
  }))
  await page.route('**/api/v1/organizer/events/42/finance', route => json(route, {
    preview: {
      gross_cents: 5000, refund_cents: 0, processing_fee_cents: 183,
      payable_cents: 4817, negative_balance_cents: 0
    },
    settlements: [{ id: 9, version: 1, status: 'finalized', available_to_payout_cents: 4817 }],
    payouts: [],
    connected_account: { provider: 'paypal', payout_ready: true }
  }))
  await page.route('**/api/v1/organizer/events/42', route => json(route, {
    id: 42, title: 'Guam Night Market', status: 'completed'
  }))

  await page.goto('/dashboard/events/42/analytics')

  await expect(page.getByRole('heading', { name: 'Settlement and payout' })).toBeVisible()
  await expect(page.getByText('$48.17').first()).toBeVisible()
  await expect(page.getByText('paypal ready')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Pay $48.17' })).toBeEnabled()
})
